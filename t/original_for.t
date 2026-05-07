use warnings;
use strict;

use Test::More;
use Test::MockModule;
use Scalar::Util qw(refaddr);

package Tgt::OriginalFor;
our $VERSION = 1;
sub greet { 'hello' }
sub other { 'other' }
package main;

# 1. Returns the actual sub when not mocked
{
    my $code = Test::MockModule->original_for('Tgt::OriginalFor', 'greet');
    is(ref($code), 'CODE', 'returns a coderef when sub is not mocked');
    is($code->(), 'hello', '... that calls the real implementation');
}

# 2. Returns the truly-original (not the active mock) when mocked
{
    my $mock = Test::MockModule->new('Tgt::OriginalFor');
    $mock->mock('greet', sub { 'mocked' });

    is(Tgt::OriginalFor::greet(), 'mocked', 'symbol table now holds the mock');

    my $orig = Test::MockModule->original_for('Tgt::OriginalFor', 'greet');
    is($orig->(), 'hello',
        'original_for returns the pre-mock implementation, not the mock');
}

# 3. The recommended GH #83-safe pattern: closure captures strings, not $mock
{
    my @results;
    my $run = sub {
        my ($label) = @_;
        my $mock = Test::MockModule->new('Tgt::OriginalFor', no_auto => 1);
        $mock->mock('greet', sub {
            # No $mock capture -- only the package and sub name strings
            return Test::MockModule
                ->original_for('Tgt::OriginalFor', 'greet')->() . "_$label";
        });
        push @results, Tgt::OriginalFor::greet();
    };
    $run->('first');
    $run->('second');
    is_deeply \@results, ['hello_first', 'hello_second'],
        'original_for pattern does not leak past lexical scope (GH #83 fix)';
}

# 4. Stacked mocks: original_for still returns the truly-original
{
    my $m1 = Test::MockModule->new('Tgt::OriginalFor');
    $m1->mock('other', sub { 'L1' });
    {
        my $m2 = Test::MockModule->new('Tgt::OriginalFor');
        $m2->mock('other', sub { 'L2' });
        is(Tgt::OriginalFor::other(), 'L2', 'top mock wins');
        my $orig = Test::MockModule->original_for('Tgt::OriginalFor', 'other');
        is($orig->(), 'other',
            'original_for returns pre-any-mock impl, not the layer below');
    }
}

# 5. Invalid args croak
{
    eval { Test::MockModule->original_for('', 'foo') };
    like($@, qr/Invalid package name/, 'empty package croaks');

    eval { Test::MockModule->original_for('Tgt::OriginalFor', '') };
    like($@, qr/valid function name/i, 'empty sub name croaks');
}

# 6. Looking up a sub that doesn't exist returns undef without crashing
{
    my $code = Test::MockModule->original_for('Tgt::OriginalFor', 'nonexistent');
    is($code, undef, 'returns undef for nonexistent sub');
}

# 7. define()'d subs: original_for must return undef, not the live mock.
#    The bottom-of-stack orig is undef in this case (the sub had no
#    pre-mock implementation). Falling through to \&{$sub_name} would
#    return the active mock and cause infinite recursion if the user's
#    closure called original_for to "wrap" itself.
{
    package Tgt::DefineOnly;
    our $VERSION = 1;
    package main;

    my $mock = Test::MockModule->new('Tgt::DefineOnly');
    $mock->define('brandnew', sub { 'mocked' });
    is(Tgt::DefineOnly::brandnew(), 'mocked', 'define()d sub callable');

    my $orig = Test::MockModule->original_for('Tgt::DefineOnly', 'brandnew');
    is($orig, undef,
        'original_for returns undef for define()d sub (no pre-mock impl, no fall-through to live mock)');
}

done_testing;
