use warnings;
use strict;

use Test::More;
use Test::MockModule;

package Tgt::ResetFor;
our $VERSION = 1;
sub greet { 'hello' }
sub other { 'other' }
package main;

# 1. reset_for restores all subs in the named package
{
    my $mock = Test::MockModule->new('Tgt::ResetFor');
    $mock->mock('greet', sub { 'mocked_greet' });
    $mock->mock('other', sub { 'mocked_other' });

    is(Tgt::ResetFor::greet(), 'mocked_greet', 'greet mocked');
    is(Tgt::ResetFor::other(), 'mocked_other', 'other mocked');

    Test::MockModule->reset_for('Tgt::ResetFor');

    is(Tgt::ResetFor::greet(), 'hello', 'greet restored after reset_for');
    is(Tgt::ResetFor::other(), 'other', 'other restored after reset_for');
}

# 2. reset_for unsticks the GH #83 leak pattern
{
    my @results;
    my $run = sub {
        my ($label) = @_;
        my $mock = Test::MockModule->new('Tgt::ResetFor', no_auto => 1);
        $mock->mock('greet', sub {
            return $mock->original('greet')->() . "_$label";
        });
        push @results, Tgt::ResetFor::greet();
        # Explicit teardown bypasses DESTROY-leak
        Test::MockModule->reset_for('Tgt::ResetFor');
    };
    $run->('a');
    $run->('b');
    is_deeply \@results, ['hello_a', 'hello_b'],
        'reset_for fixes GH #83 leak when called explicitly';
}

# 3. reset_for is scoped to the named package only
{
    package Other::ResetFor;
    our $VERSION = 1;
    sub greet { 'other_pkg' }
    package main;

    my $a = Test::MockModule->new('Tgt::ResetFor');
    my $b = Test::MockModule->new('Other::ResetFor');
    $a->mock('greet', sub { 'A_mocked' });
    $b->mock('greet', sub { 'B_mocked' });

    Test::MockModule->reset_for('Tgt::ResetFor');

    is(Tgt::ResetFor::greet(), 'hello',     'A package reset');
    is(Other::ResetFor::greet(), 'B_mocked', 'B package untouched');

    Test::MockModule->reset_for('Other::ResetFor');
    is(Other::ResetFor::greet(), 'other_pkg', 'B package reset on second call');
}

# 4. reset_for on a package with no mocks is a no-op (no croak)
{
    package Untouched::ResetFor;
    our $VERSION = 1;
    sub thing { 'untouched' }
    package main;

    eval { Test::MockModule->reset_for('Untouched::ResetFor') };
    is($@, '', 'reset_for on un-mocked package does not croak');
    is(Untouched::ResetFor::thing(), 'untouched',
        '... and leaves the sub alone');
}

# 5. reset_for with invalid package name croaks
{
    eval { Test::MockModule->reset_for('') };
    like($@, qr/Invalid package name/, 'empty package name croaks');

    eval { Test::MockModule->reset_for('123Invalid') };
    like($@, qr/Invalid package name/, 'numeric-leading package name croaks');
}

done_testing;
