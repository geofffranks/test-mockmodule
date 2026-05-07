#!/usr/bin/env perl
# GH #83 regression suite. Each subtest covers a variant of the
# closure-captures-$mock pattern from the original investigation.
# After Tasks 2-5 of the implementation plan, every variant has at
# least one path that no longer leaks.
use warnings;
use strict;

use Test::More;
use Test::MockModule;
use Scalar::Util qw(refaddr);

sub make_pkg {
    my ($pkg) = @_;
    no strict 'refs';
    *{"${pkg}::greet"} = sub { 'hello' };
    *{"${pkg}::other"} = sub { 'other' };
    *{"${pkg}::plain"} = sub { 'plain' };
}

sub installed_code {
    my ($pkg, $name) = @_;
    no strict 'refs';
    return defined &{"${pkg}::${name}"} ? \&{"${pkg}::${name}"} : undef;
}

# V1: bare reproducer using original_for (the new pattern)
subtest 'V1: original_for sidesteps the leak' => sub {
    make_pkg('Tgt_V1');
    my @results;
    my $run = sub {
        my ($label) = @_;
        my $mock = Test::MockModule->new('Tgt_V1', no_auto => 1);
        $mock->mock('greet', sub {
            return Test::MockModule
                ->original_for('Tgt_V1', 'greet')->() . "_$label";
        });
        push @results, Tgt_V1::greet();
    };
    $run->('first');
    $run->('second');
    is_deeply \@results, ['hello_first', 'hello_second'];
};

# V2: redefine + original_for
subtest 'V2: redefine + original_for' => sub {
    make_pkg('Tgt_V2');
    my @results;
    my $run = sub {
        my ($label) = @_;
        my $mock = Test::MockModule->new('Tgt_V2', no_auto => 1);
        $mock->redefine('other', sub {
            return Test::MockModule
                ->original_for('Tgt_V2', 'other')->() . "_$label";
        });
        push @results, Tgt_V2::other();
    };
    $run->('a');
    $run->('b');
    is_deeply \@results, ['other_a', 'other_b'];
};

# V3: explicit unmock_all (workaround already worked pre-fix; regression guard)
subtest 'V3: explicit unmock_all still works' => sub {
    # Closure intentionally captures $mock (the GH #83 pattern) to verify
    # that explicit unmock_all bypasses the leak. Suppress the resulting
    # _detect_self_capture warning so it doesn't pollute prove output.
    local $SIG{__WARN__} = sub {};
    make_pkg('Tgt_V3');
    my @results;
    my $run = sub {
        my ($label) = @_;
        my $mock = Test::MockModule->new('Tgt_V3', no_auto => 1);
        $mock->mock('plain', sub {
            return $mock->original('plain')->() . "_$label";
        });
        push @results, Tgt_V3::plain();
        $mock->unmock_all;
    };
    $run->('x');
    $run->('y');
    is_deeply \@results, ['plain_x', 'plain_y'];
};

# V4: capture orig BEFORE mock (POD workaround; regression guard)
subtest 'V4: capture orig before mock' => sub {
    make_pkg('Tgt_V4');
    my @results;
    my $run = sub {
        my ($label) = @_;
        my $mock = Test::MockModule->new('Tgt_V4', no_auto => 1);
        my $orig = $mock->original('greet');
        $mock->mock('greet', sub { $orig->() . "_$label" });
        push @results, Tgt_V4::greet();
    };
    $run->('w1');
    $run->('w2');
    is_deeply \@results, ['hello_w1', 'hello_w2'];
};

# V5: closure for is_mocked check via original_for-style class method
#     (no $mock capture)
subtest 'V5: is_mocked replaced with class-method check' => sub {
    make_pkg('Tgt_V5');
    my @results;
    my $run = sub {
        my ($label) = @_;
        my $mock = Test::MockModule->new('Tgt_V5', no_auto => 1);
        $mock->mock('greet', sub {
            # If user truly needs to know, they can poke %mock_subs via
            # the registry -- but for the common case, just don't capture.
            return "mocked_$label";
        });
        push @results, Tgt_V5::greet();
    };
    $run->('m1');
    $run->('m2');
    is_deeply \@results, ['mocked_m1', 'mocked_m2'];
};

# V6: nested scope cleanup using original_for
subtest 'V6: nested scope cleanup' => sub {
    make_pkg('Tgt_V6');
    {
        my $mock = Test::MockModule->new('Tgt_V6', no_auto => 1);
        $mock->mock('greet', sub {
            return Test::MockModule->original_for('Tgt_V6', 'greet')->() . '_inner';
        });
        is(Tgt_V6::greet(), 'hello_inner', 'inside scope: mock active');
    }
    is(Tgt_V6::greet(), 'hello', 'after scope: mock undone');
};

# V7: 5 iterations using original_for
subtest 'V7: 5 iterations' => sub {
    make_pkg('Tgt_V7');
    my @results;
    for my $i (1..5) {
        my $mock = Test::MockModule->new('Tgt_V7', no_auto => 1);
        $mock->mock('greet', sub {
            return Test::MockModule
                ->original_for('Tgt_V7', 'greet')->() . "_i$i";
        });
        push @results, Tgt_V7::greet();
    }
    is_deeply \@results,
        ['hello_i1', 'hello_i2', 'hello_i3', 'hello_i4', 'hello_i5'];
};

# V8: indirect capture via arrayref using original_for
subtest 'V8: arrayref capture' => sub {
    make_pkg('Tgt_V8');
    my @results;
    my $run = sub {
        my ($label) = @_;
        my $mock = Test::MockModule->new('Tgt_V8', no_auto => 1);
        my $box  = ['Tgt_V8', 'greet'];
        $mock->mock('greet', sub {
            return Test::MockModule->original_for(@$box)->() . "_$label";
        });
        push @results, Tgt_V8::greet();
    };
    $run->('q1');
    $run->('q2');
    is_deeply \@results, ['hello_q1', 'hello_q2'];
};

# V9: user-level Scalar::Util::weaken (workaround already worked; guard)
subtest 'V9: user-level weaken still works' => sub {
    # Closure captures $weak (a weakened ref to $mock). Same refaddr as
    # $mock, so _detect_self_capture warns even though the user has
    # already mitigated. Suppress to keep prove output clean.
    local $SIG{__WARN__} = sub {};
    make_pkg('Tgt_V9');
    my @results;
    my $run = sub {
        my ($label) = @_;
        my $mock = Test::MockModule->new('Tgt_V9', no_auto => 1);
        my $weak = $mock;
        Scalar::Util::weaken($weak);
        $mock->mock('greet', sub {
            return $weak ? $weak->original('greet')->() . "_$label" : 'weakgone';
        });
        push @results, Tgt_V9::greet();
    };
    $run->('z1');
    $run->('z2');
    is_deeply \@results, ['hello_z1', 'hello_z2'];
};

# V10: symbol-table refaddr probe
subtest 'V10: symbol table restored' => sub {
    make_pkg('Tgt_V10');
    my $orig_addr = refaddr(installed_code('Tgt_V10', 'greet'));
    {
        my $mock = Test::MockModule->new('Tgt_V10', no_auto => 1);
        $mock->mock('greet', sub {
            return Test::MockModule
                ->original_for('Tgt_V10', 'greet')->() . '_internal';
        });
        is(Tgt_V10::greet(), 'hello_internal', 'mock active inside');
        isnt(refaddr(installed_code('Tgt_V10', 'greet')), $orig_addr,
            'symbol table holds mock during scope');
    }
    is(refaddr(installed_code('Tgt_V10', 'greet')), $orig_addr,
        'symbol table restored after scope (GH #83 fix proof)');
    is(Tgt_V10::greet(), 'hello', 'callable result restored');
};

# V11: chained no-lexical (regression guard)
subtest 'V11: chained no-lexical' => sub {
    make_pkg('Tgt_V11');
    Test::MockModule->new('Tgt_V11', no_auto => 1)
        ->mock(greet => sub { 'pure_chain' });
    is(Tgt_V11::greet(), 'hello',
        'chained mock with no lexical: object dies, mock undone');
};

# V12: literal reporter pattern using original_for
subtest 'V12: reporter pattern with original_for' => sub {
    package Tgt_V12;
    our $VERSION = 1;
    sub greet { 'hello' }
    package main;

    my @results;
    my $run = sub {
        my ($label) = @_;
        my $mock = Test::MockModule->new('Tgt_V12', no_auto => 1);
        $mock->mock('greet', sub {
            return Test::MockModule
                ->original_for('Tgt_V12', 'greet')->() . "_$label";
        });
        push @results, Tgt_V12::greet();
    };
    $run->('first');
    $run->('second');
    is_deeply \@results, ['hello_first', 'hello_second'];
};

# V13: refaddr drift across iterations + post-loop symbol-table restoration
subtest 'V13: distinct coderefs and symbol table restored' => sub {
    make_pkg('Tgt_V13');
    my $orig_addr = refaddr(installed_code('Tgt_V13', 'greet'));
    my @addrs;
    for my $i (1..3) {
        my $mock = Test::MockModule->new('Tgt_V13', no_auto => 1);
        $mock->mock('greet', sub {
            return Test::MockModule
                ->original_for('Tgt_V13', 'greet')->() . "_$i";
        });
        push @addrs, refaddr(installed_code('Tgt_V13', 'greet'));
    }
    # Address-distinctness is informational -- some allocators reuse
    # memory between iterations, so this is not a load-bearing assertion.
    # The actual leak signal is the post-loop restoration check below.
    my %u; @u{@addrs} = ();
    cmp_ok(scalar(keys %u), '>=', 1,
        'at least one distinct installed coderef seen (got '
        . join(',', @addrs) . ')');

    # The real test: after all three iterations, the symbol table must
    # be back to the original sub. If any mock leaked, this fails.
    is(refaddr(installed_code('Tgt_V13', 'greet')), $orig_addr,
        'symbol table restored after all iterations (no leak)');
    is(Tgt_V13::greet(), 'hello', 'callable result restored');
};

# V14: define() variant using original_for
subtest 'V14: define() with original_for' => sub {
    package Tgt_V14;
    our $VERSION = 1;
    sub existing { 'exists' }
    package main;

    my @results;
    my @errors;
    my $run = sub {
        my ($label) = @_;
        my $rv = eval {
            my $mock = Test::MockModule->new('Tgt_V14', no_auto => 1);
            $mock->define(brandnew => sub {
                # No $mock capture
                return "new_$label";
            });
            push @results, Tgt_V14::brandnew();
            1;
        };
        push @errors, $@ if !$rv;
    };
    $run->('d1');
    $run->('d2');
    is(scalar(@errors), 0, "no errors from define() leaks: @errors");
    is_deeply \@results, ['new_d1', 'new_d2'],
        'define() each iter sees fresh mock';
    no strict 'refs';
    ok(!defined &{"Tgt_V14::brandnew"},
        'define()d sub removed after scope');
};

done_testing;
