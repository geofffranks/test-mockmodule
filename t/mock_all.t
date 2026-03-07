use warnings;
use strict;

use Test::More;
use Test::Warnings;

use Test::MockModule;

# Set up test package with multiple subs
{
    package MockAllTarget;
    our $VERSION = 1;

    sub alpha   { return 'alpha' }
    sub beta    { return 'beta' }
    sub gamma   { return 'gamma' }
    sub _private { return 'private' }
    sub import  { return 'import' }  # should be skipped
}

# 1. Default behavior: die on unmocked call
{
    my $mock = Test::MockModule->new('MockAllTarget');
    $mock->mock_all();

    eval { MockAllTarget::alpha() };
    like( $@, qr/MockAllTarget::alpha was not mocked/, 'mock_all dies on unmocked call (alpha)' );

    eval { MockAllTarget::beta() };
    like( $@, qr/MockAllTarget::beta was not mocked/, 'mock_all dies on unmocked call (beta)' );

    # import should NOT be mocked
    is( MockAllTarget::import(), 'import', 'mock_all skips import()' );
}

# Verify unmocking restores originals
is( MockAllTarget::alpha(), 'alpha', 'alpha restored after mock object goes out of scope' );
is( MockAllTarget::beta(), 'beta', 'beta restored after mock object goes out of scope' );

# 2. noop mode
{
    my $mock = Test::MockModule->new('MockAllTarget');
    $mock->mock_all(noop => 1);

    is( MockAllTarget::alpha(), undef, 'noop mode returns undef (alpha)' );
    is( MockAllTarget::beta(), undef, 'noop mode returns undef (beta)' );
}
is( MockAllTarget::alpha(), 'alpha', 'alpha restored after noop mock goes out of scope' );

# 3. Custom handler
{
    my $mock = Test::MockModule->new('MockAllTarget');
    $mock->mock_all(handler => sub { return 'handled' });

    is( MockAllTarget::alpha(), 'handled', 'custom handler works (alpha)' );
    is( MockAllTarget::gamma(), 'handled', 'custom handler works (gamma)' );
}
is( MockAllTarget::gamma(), 'gamma', 'gamma restored after handler mock goes out of scope' );

# 4. Already-mocked subs are skipped
{
    my $mock = Test::MockModule->new('MockAllTarget');
    $mock->redefine('alpha', sub { return 'custom_alpha' });
    $mock->mock_all();

    is( MockAllTarget::alpha(), 'custom_alpha', 'already-mocked sub keeps its mock' );
    eval { MockAllTarget::beta() };
    like( $@, qr/MockAllTarget::beta was not mocked/, 'non-mocked sub gets mock_all treatment' );
}

# 5. Chaining works
{
    my $mock = Test::MockModule->new('MockAllTarget');
    my $ret = $mock->mock_all(noop => 1);
    is( $ret, $mock, 'mock_all returns $self for chaining' );
}

# 6. Private subs are mocked too
{
    my $mock = Test::MockModule->new('MockAllTarget');
    $mock->mock_all();

    eval { MockAllTarget::_private() };
    like( $@, qr/MockAllTarget::_private was not mocked/, 'private subs are mocked by mock_all' );
}

# 7. Selective unmocking after mock_all
{
    my $mock = Test::MockModule->new('MockAllTarget');
    $mock->mock_all();
    $mock->unmock('alpha');

    is( MockAllTarget::alpha(), 'alpha', 'unmock restores individual sub after mock_all' );
    eval { MockAllTarget::beta() };
    like( $@, qr/MockAllTarget::beta was not mocked/, 'other subs remain mocked' );
}

# 8. mock_all + redefine specific subs
{
    my $mock = Test::MockModule->new('MockAllTarget');
    $mock->mock_all();
    $mock->redefine('alpha', sub { return 'real_mock' });

    is( MockAllTarget::alpha(), 'real_mock', 'redefine after mock_all works' );
    eval { MockAllTarget::beta() };
    like( $@, qr/MockAllTarget::beta was not mocked/, 'mock_all still covers other subs' );
}

done_testing();
