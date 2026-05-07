use warnings;
use strict;

use Test::More;
use Test::MockModule;

package Tgt;
our $VERSION = 1;
sub greet { 'hello' }
package main;

# 1. The buggy pattern: closure captures $mock to call ->original
{
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    my $mock = Test::MockModule->new('Tgt');
    $mock->mock('greet', sub {
        return $mock->original('greet')->() . '_x';
    });

    is(scalar(@warnings), 1, 'one warning emitted for closure-captures-self')
        or diag explain \@warnings;
    like($warnings[0], qr/captures the mock object/i,
        'warning text mentions mock object capture');
    like($warnings[0], qr/GH ?#?83/i,
        'warning references GH #83');
    like($warnings[0], qr/original_for/,
        'warning recommends original_for');
}

# 2. The recommended pattern: capture orig before mocking -- no warning
{
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    my $mock = Test::MockModule->new('Tgt');
    my $orig = $mock->original('greet');
    $mock->mock('greet', sub { $orig->() . '_x' });

    is(scalar(@warnings), 0,
        'no warning when closure captures only $orig, not $mock')
        or diag explain \@warnings;
}

# 3. Plain non-closure mock -- no warning
{
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    my $mock = Test::MockModule->new('Tgt');
    $mock->mock('greet', sub { 'flat' });

    is(scalar(@warnings), 0, 'no warning for non-closure mock')
        or diag explain \@warnings;
}

# 4. Scalar value mock (not a coderef at all) -- no warning, no crash
{
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    my $mock = Test::MockModule->new('Tgt');
    $mock->mock('greet', 'plain_scalar');

    is(scalar(@warnings), 0, 'no warning when mocking with a scalar value')
        or diag explain \@warnings;
    is(Tgt::greet(), 'plain_scalar', 'scalar mock works');
}

# 5. Closure captures something OTHER than $mock -- no false positive
{
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    my $other = bless {}, 'Some::Other';
    my $mock = Test::MockModule->new('Tgt');
    $mock->mock('greet', sub { ref($other) });

    is(scalar(@warnings), 0,
        'no warning when closure captures unrelated object')
        or diag explain \@warnings;
}

done_testing;
