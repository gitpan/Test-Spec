package Test::Spec::Context;
use strict;
use warnings;

########################################################################
# NO USER-SERVICEABLE PARTS INSIDE.
########################################################################

use Carp ();
use List::Util ();
use Scalar::Util ();
use Test::More ();
use Test::Spec qw(*TODO $Debug :constants);

our $_StackDepth = 0;

sub new {
  my $class = shift;
  my $self = bless {}, $class;
  if (@_) {
    my $args = shift;
    if (@_ || ref($args) ne 'HASH') {
      Carp::croak "usage: $class->new(\\%args)";
    }
    while (my ($name,$val) = each (%$args)) {
      $self->$name($val);
    }
  }

  $self->on_enter(sub {
    $self->_debug(sub {
      printf STDERR "%s[%s]\n", '  ' x $_StackDepth, $self->_debug_name;
      $_StackDepth++;
    });
  });

  $self->on_leave(sub {
    $self->_debug(sub {
      $_StackDepth--;
      printf STDERR "%s[/%s]\n", '  ' x $_StackDepth, $self->_debug_name;
    });
  });

  return $self;
}

sub clone {
  my $orig = shift;
  my $clone = bless { %$orig }, ref($orig);

  my $orig_contexts = $clone->context_lookup;
  my $new_contexts  = Test::Spec::_ixhash();

  while (my ($name,$ctx) = each %$orig_contexts) {
    my $new_ctx = $ctx->clone;
    $new_ctx->parent($clone);
    $new_contexts->{$name} = $new_ctx;
  }
  $clone->{_context_lookup} = $new_contexts;

  return $clone;
}

# The reference we keep to our parent causes the garbage collector to
# destroy the innermost context first, which is what we want. If that
# becomes untrue at some point, it will be easy enough to descend the
# hierarchy and run the after("all") tests that way.
sub DESTROY {
  my $self = shift;
  # no need to tear down what was never set up
  if ($self->_has_run_before_all) {
    $self->_run_after_all_once;
  }
}

sub name {
  my $self = shift;
  $self->{_name} = shift if @_;
  return exists($self->{_name})
    ? $self->{_name}
    : ($self->{_name} = '');
}

sub parent {
  my $self = shift;
  if (@_) {
    $self->{_parent} = shift;
    Scalar::Util::weaken($self->{_parent}) if ref($self->{_parent});
  }
  return $self->{_parent};
}

sub class {
  my $self = shift;
  $self->{_class} = shift if @_;
  if ($self->{_class}) {
    return $self->{_class};
  }
  elsif ($self->parent) {
    return $self->parent->class;
  }
  else {
    return undef;
  }
}

sub context_lookup {
  my $self = shift;
  return $self->{_context_lookup} ||= Test::Spec::_ixhash();
}

sub before_blocks {
  my $self = shift;
  return $self->{_before_blocks} ||= [];
}

sub after_blocks {
  my $self = shift;
  return $self->{_after_blocks} ||= [];
}

sub tests {
  my $self = shift;
  return $self->{_tests} ||= [];
}

sub on_enter_blocks {
  my $self = shift;
  return $self->{_on_enter_blocks} ||= [];
}

sub on_leave_blocks {
  my $self = shift;
  return $self->{_on_leave_blocks} ||= [];
}

# private attributes
sub _has_run_before_all {
  my $self = shift;
  $self->{__has_run_before_all} = shift if @_;
  return $self->{__has_run_before_all};
}

sub _has_run_after_all {
  my $self = shift;
  $self->{__has_run_after_all} = shift if @_;
  return $self->{__has_run_after_all};
}

sub _debug {
  my ($self,$code) = @_;
  return unless $self->_debugging;
  $code->();
}

sub _debug_name {
  my $self = shift;
  $self->name || '(anonymous)';
}

sub _debugging {
  my $self = shift;
  # env var can be set greater than 1 for definition phase debug.
  # otherwise, any true value means debug execution
  if ($Debug > 1) {
    return 1;
  }
  elsif ($Debug && $self->class->phase == EXECUTION_PHASE) {
    return 1;
  }
  return;
}

sub on_enter {
  my ($self,$callback) = @_;
  push @{ $self->on_enter_blocks }, $callback;

  # Handle case where an on_enter was added during a context declaration.
  # This allows stubs being set up to be valid both in that current Perl
  # context and later in spec context.
  if (Test::Spec->in_context($self)) {
    if (not $self->{_has_run_on_enter}{$callback}++) {
      $callback->();
    }
  }
  return;
}

sub on_leave {
  my ($self,$callback) = @_;
  push @{ $self->on_leave_blocks }, $callback;
}

sub ancestors {
  my ($self) = @_;
  return $self->parent ? ($self->parent, $self->parent->ancestors) : ();
}

sub ancestor_of {
  my ($self,$other) = @_;
  return !!List::Util::first { $other == $_ } $self->ancestors;
}

sub contexts {
  my $self = shift;
  my @ctx = values %{ $self->context_lookup };
  return wantarray ? @ctx : \@ctx;
}

# recurse into child contexts to count total tests for a package
sub _count_tests {
  my $self = shift;
  my @descendant = map { $_->_count_tests } $self->contexts;
  return @{$self->tests} + List::Util::sum(0, @descendant);
}

sub _run_callback {
  my ($self,$type,$pool,@args) = @_;
  my @subs = map { $_->{code} } grep { $_->{type} eq $type } @$pool;
  for my $code (@subs) {
    $code->(@args);
  }
}

sub _run_before {
  my $self = shift;
  my $type = shift;
  return $self->_run_callback($type,$self->before_blocks,@_);
}

sub _run_before_all_once {
  my $self = shift;
  return if $self->_has_run_before_all;
  $self->_has_run_before_all(1);
  return $self->_run_before('all',@_);
}

sub _run_after {
  my $self = shift;
  my $type = shift;
  return $self->_run_callback($type,$self->after_blocks,@_);
}

sub _run_after_all_once {
  my $self = shift;
  return if $self->_has_run_after_all;
  $self->_has_run_after_all(1);
  return $self->_run_after('all',@_);
}

# join by spaces and strip leading/extra spaces
sub _concat {
  my ($self,@pieces) = @_;
  my $str = join(' ', @pieces);
  $str =~ s{\A\s+|\s+\z}{}s;
  $str =~ s{\s+}{ }sg;
  return $str;
}

sub _materialize_tests {
  my ($self, $digits, @context_stack) = @_;

  # include the name of the context in test reports
  push @context_stack, $self;

  # need to know how many tests there are, so we can make a lexically
  # sortable test name using numeric prefix.
  if (not defined $digits) {
    my $top_level_sum = List::Util::sum(
      map { $_->_count_tests } $self->class->contexts
    );
    if ($top_level_sum == 0) {
      warn "no examples defined in spec package " . $self->class;
      return;
    }
    $digits = 1 + int( log($top_level_sum) / log(10) );
  }

  # Create a test sub like 't001_enough_mucus'
  my $format = "t%0${digits}d_%s";

  for my $t (@{ $self->tests }) {
    my $description = $self->_concat((map { $_->name } @context_stack), $t->{name});
    my $test_number = 1 + scalar($self->class->tests);
    my $sub_name    = sprintf $format, $test_number, $self->_make_safe($description);
    my $fq_name     = $self->class . '::' . $sub_name;

    # create a test subroutine in the correct package
    no strict 'refs';
    *{$fq_name} = sub {
      if (!$t->{code} || $t->{todo}) {
        my $builder = $self->_builder;
        local $TODO = $t->{todo} || "(unimplemented)";
        $builder->todo_start($TODO);
        $builder->ok(1, $description);
        $builder->todo_end();
      }
      else {
        # copy these, because they'll be needed in a callback with its own @_
        my @test_args = @_;

        # clobber Test::Builder's ok() method just like Test::Class does,
        # but without screwing up underscores.
        no warnings 'redefine';
        my $orig_builder_ok = \&Test::Builder::ok;
        local *Test::Builder::ok = sub {
          my ($builder,$test,$desc) = splice(@_,0,3);
          $desc ||= $description;
          local $Test::Builder::Level = $Test::Builder::Level+1;
          $orig_builder_ok->($builder, $test, $desc, @_);
        };

        # This recursive closure essentially does this
        # $outer->contextualize {
        #   $outer->before_each
        #   $inner->contextualize {
        #     $inner->before_each
        #     $anon->contextualize {
        #       $anon->before_each (no-op)
        #         execute test
        #       $anon->after_each (no-op)
        #     }
        #     $inner->after_each
        #   }
        #   $outer->after_each
        # }
        #
        my $runner;
        $runner = sub {
          my ($ctx,@remainder) = @_;
          $ctx->contextualize(sub {
            $ctx->_run_before_all_once;
            $ctx->_run_before('each');
            if ($ctx == $self) {
              $self->_in_anonymous_context(sub { $t->{code}->(@test_args) });
            }
            else {
              $runner->(@remainder);
            }
            $ctx->_run_after('each');
            # "after 'all'" only happens during context destruction (DEMOLISH).
            # This is the only way I can think to make this work right
            # in the case that only specific test methods are run.
            # Otherwise, the global teardown would only happen when you
            # happen to run the last test of the context.
          });
        };
        eval { $runner->(@context_stack) };
        if (my $err = $@) {
          my $builder = $self->_builder;
          # eval in case stringification overload croaks
          chomp($err = eval { $err . '' } || 'unknown error');
          my ($file,$line);
          ($file,$line) = ($1,$2) if ($err =~ s/ at (.+?) line (\d+)\.\Z//);

          # disable ok()'s diagnostics so we can generate a custom TAP message
          my $old_diag = $builder->no_diag;
          $builder->no_diag(1);
          # make sure we can restore no_diag
          eval { $builder->ok(0, $description) };
          my $secondary_err = $@;
          # no_diag needs a defined value, so double-negate it to get either '' or 1
          $builder->no_diag(!!$old_diag);

          unless ($builder->no_diag) {
            # emulate Test::Builder::ok's diagnostics, but with more details
            my ($msg,$diag_fh);
            if ($builder->in_todo) {
              $msg = "Failed (TODO)";
              $diag_fh = $builder->todo_output;
            }
            else {
              $msg = "Failed";
              $diag_fh = $builder->failure_output;
            }
            print {$diag_fh} "\n" if $ENV{HARNESS_ACTIVE};
            print {$builder->failure_output} qq[#   $msg test '$description' by dying:\n];
            print {$builder->failure_output} qq[#     $err\n];
            print {$builder->failure_output} qq[#     at $file line $line.\n] if defined($file);
          }
          die $secondary_err if $secondary_err;
        }
      }

      $self->_debug(sub { print STDERR "\n" });
    };

    $self->class->add_test($sub_name);
  }

  # recurse to child contexts
  for my $ctx ($self->contexts) {
    $ctx->_materialize_tests($digits, @context_stack);
  }
}

sub _builder {
  shift->class->builder;
}

sub _make_safe {
  my ($self,$str) = @_;
  return '' unless (defined($str) && length($str));
  $str = lc($str);
  $str =~ s{'}{}g;
  $str =~ s{\W+}{_}g;
  $str =~ s{_+}{_}g;
  return $str;
}

# Recurse to run the entire on_enter chain, starting from the top.
# Propagate exceptions in the same way that _run_on_leave does, for the same
# reasons.
sub _run_on_enter {
  my $self = shift;
  my @errs;
  if ($self->parent) {
    eval { $self->parent->_run_on_enter };
    push @errs, $@ if $@;
  }
  for my $on_enter (@{ $self->on_enter_blocks }) {
    next if $self->{_has_run_on_enter}{$on_enter}++;
    eval { $on_enter->() };
    push @errs, $@ if $@;
  }
  die join("\n", @errs) if @errs;
  return;
}

# Recurse to run the entire on_leave chain, starting from the bottom (and in
# reverse "unwinding" order).
# Propagate all exceptions only after running all on_leave blocks. This allows
# mocks (and whatever else) to test their expectations after the test has
# completed.
sub _run_on_leave {
  my $self = shift;
  my @errs;
  for my $on_leave (reverse @{ $self->on_leave_blocks }) {
    next if $self->{_has_run_on_leave}{$on_leave}++;
    eval { $on_leave->() };
    push @errs, $@ if $@;
  }
  if ($self->parent) {
    eval { $self->parent->_run_on_leave };
    push @errs, $@ if $@;
  }
  die join("\n", @errs) if @errs;
  return;
}

# for giving individual tests mortal, anonymous contexts that are used for
# mocking/stubbing hooks.
sub _in_anonymous_context {
  my ($self,$code) = @_;
  my $context = Test::Spec::Context->new;
  $context->name('');
  $context->parent($self);
  $context->class($self->class);
  $context->contextualize($code);
}

# Runs $code within a context (specifically, having been wrapped with
# on_enter/on_leave setup and teardown).
sub contextualize {
  my ($self,$code) = @_;
  local $Test::Spec::_Current_Context = $self;
  local $self->{_has_run_on_enter} = {};
  local $self->{_has_run_on_leave} = {};
  local $TODO = $TODO;
  my @errs;

  eval { $self->_run_on_enter };
  push @errs, $@ if $@;

  if (not @errs) {
    eval { $code->() };
    push @errs, $@ if $@;
  }

  # always run despite errors, since on_enter might have set up stuff that
  # needs to be torn down, before another on_enter died
  eval { $self->_run_on_leave };
  push @errs, $@ if $@;

  if (@errs) {
    if ($TODO) {
      # make it easy for tests to declare todo status, just "$TODO++"
      $TODO = "(unimplemented)" if $TODO =~ /^\d+$/;
      # expected to fail
      Test::More::ok(1);
    }
    else {
      # rethrow
      die join("\n", @errs);
    }
  }

  return;
}

#
# Copyright (c) 2010-2011 by Informatics Corporation of America.
# 
# This program is free software; you can redistribute it and/or modify it
# under the same terms as Perl itself.
#

1;
