use warnings;
use strict;

use Test::More;
use Test::Warnings;
use Test::MockModule;

use lib "t/lib";

# Test package
package Stacked;
our $VERSION = 1;
sub foo { 'original_foo' }
sub bar { 'original_bar' }
package main;

# Basic: new() returns distinct objects
{
    my $m1 = Test::MockModule->new('Stacked');
    my $m2 = Test::MockModule->new('Stacked');
    isnt($m1, $m2, 'new() returns distinct objects for same package');
    is($m1->get_package, 'Stacked', '... both target the same package');
    is($m2->get_package, 'Stacked', '... both target the same package');
}

# Independent mocking: different subs on different objects
{
    my $m1 = Test::MockModule->new('Stacked');
    $m1->mock('foo', sub { 'mock1_foo' });
    is(Stacked::foo(), 'mock1_foo', 'first object mocks foo');
    is(Stacked::bar(), 'original_bar', 'bar is untouched');

    {
        my $m2 = Test::MockModule->new('Stacked');
        $m2->mock('bar', sub { 'mock2_bar' });
        is(Stacked::foo(), 'mock1_foo', 'foo still mocked by first object');
        is(Stacked::bar(), 'mock2_bar', 'bar mocked by second object');
    }

    is(Stacked::foo(), 'mock1_foo', 'foo still mocked after second object destroyed');
    is(Stacked::bar(), 'original_bar', 'bar restored after second object destroyed');
}

is(Stacked::foo(), 'original_foo', 'foo restored after first object destroyed');

# Stacked mocking: same sub, LIFO destruction order
{
    my $m1 = Test::MockModule->new('Stacked');
    $m1->mock('foo', sub { 'layer1' });
    is(Stacked::foo(), 'layer1', 'first layer');

    {
        my $m2 = Test::MockModule->new('Stacked');
        $m2->mock('foo', sub { 'layer2' });
        is(Stacked::foo(), 'layer2', 'second layer overrides first');
    }

    is(Stacked::foo(), 'layer1', 'first layer restored after second destroyed');
}

is(Stacked::foo(), 'original_foo', 'original restored after all objects destroyed');

# Stacked mocking: same sub, non-LIFO destruction order (inner destroyed last)
{
    my $m2;
    {
        my $m1 = Test::MockModule->new('Stacked');
        $m1->mock('foo', sub { 'layer1' });

        $m2 = Test::MockModule->new('Stacked');
        $m2->mock('foo', sub { 'layer2' });
        is(Stacked::foo(), 'layer2', 'layer2 active');
    }

    # m1 destroyed, but m2 (on top) is still alive
    is(Stacked::foo(), 'layer2', 'layer2 still active after layer1 object destroyed');

    undef $m2;
    is(Stacked::foo(), 'original_foo', 'original restored after both destroyed (non-LIFO)');
}

# Three layers
{
    my $m1 = Test::MockModule->new('Stacked');
    $m1->mock('foo', sub { 'L1' });

    my $m2 = Test::MockModule->new('Stacked');
    $m2->mock('foo', sub { 'L2' });

    my $m3 = Test::MockModule->new('Stacked');
    $m3->mock('foo', sub { 'L3' });

    is(Stacked::foo(), 'L3', 'three layers: top wins');

    # Destroy middle
    undef $m2;
    is(Stacked::foo(), 'L3', 'destroying middle does not affect top');

    # Destroy top
    undef $m3;
    is(Stacked::foo(), 'L1', 'after top and middle gone, first layer restored');

    # Destroy bottom
    undef $m1;
    is(Stacked::foo(), 'original_foo', 'all gone, original restored');
}

# Explicit unmock interacts correctly with stack
{
    my $m1 = Test::MockModule->new('Stacked');
    $m1->mock('foo', sub { 'A' });

    my $m2 = Test::MockModule->new('Stacked');
    $m2->mock('foo', sub { 'B' });

    is(Stacked::foo(), 'B', 'B is active');

    $m2->unmock('foo');
    is(Stacked::foo(), 'A', 'after unmocking B, A is restored');

    $m1->unmock('foo');
    is(Stacked::foo(), 'original_foo', 'after unmocking A, original restored');
}

# is_mocked is per-object
{
    my $m1 = Test::MockModule->new('Stacked');
    $m1->mock('foo', sub { 'x' });

    my $m2 = Test::MockModule->new('Stacked');

    ok($m1->is_mocked('foo'), 'm1 reports foo as mocked');
    ok(!$m2->is_mocked('foo'), 'm2 does not report foo as mocked');

    $m2->mock('bar', sub { 'y' });
    ok(!$m1->is_mocked('bar'), 'm1 does not report bar as mocked');
    ok($m2->is_mocked('bar'), 'm2 reports bar as mocked');
}

# original() returns the correct original per object
{
    my $orig_foo = \&Stacked::foo;
    my $m1 = Test::MockModule->new('Stacked');
    $m1->mock('foo', sub { 'first' });

    my $m2 = Test::MockModule->new('Stacked');
    $m2->mock('foo', sub { 'second' });

    is($m1->original('foo'), $orig_foo, 'm1 original is the true original');
    # m2 saved m1s mock as its "original"
    is($m2->original('foo')->(), 'first', 'm2 original is m1 mock');
}

done_testing;
