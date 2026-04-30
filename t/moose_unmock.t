use strict;
use warnings;
use Test::More;

BEGIN {
    eval { require Moose; 1 } or plan skip_all => "Moose not installed";
}

use Test::MockModule;

# Local-orig case: parent has its own foo
{
    package Issue55::UnmockLocalOrig;
    use Moose;
    sub foo { 'orig' }
}

# Inherited case: child has no local foo; inherits from parent
{
    package Issue55::UnmockParent;
    use Moose;
    sub bar { 'parent_bar' }
}
{
    package Issue55::UnmockInherited;
    use Moose;
    extends 'Issue55::UnmockParent';
}

# Local-orig: mock+unmock restores method on meta and direct call
{
    my $mock = Test::MockModule->new('Issue55::UnmockLocalOrig');
    $mock->mock( foo => sub { 'mocked' } );
    is(Issue55::UnmockLocalOrig->foo, 'mocked', "local-orig: mock visible");
    ok(Issue55::UnmockLocalOrig->meta->get_method('foo'),
        "local-orig: meta has foo while mocked");

    $mock->unmock('foo');
    is(Issue55::UnmockLocalOrig->foo, 'orig', "local-orig: original restored");
    ok(Issue55::UnmockLocalOrig->meta->get_method('foo'),
        "local-orig: meta still has foo after unmock");
}

# Inherited-orig: mock adds method, unmock should remove it from child meta
# so the inheritance lookup falls back to parent.
{
    my $mock = Test::MockModule->new('Issue55::UnmockInherited');
    $mock->mock( bar => sub { 'mocked_bar' } );
    is(Issue55::UnmockInherited->bar, 'mocked_bar', "inherited-orig: mock visible");
    ok(Issue55::UnmockInherited->meta->get_method('bar'),
        "inherited-orig: meta has bar while mocked");

    $mock->unmock('bar');
    is(Issue55::UnmockInherited->bar, 'parent_bar',
        "inherited-orig: parent method takes over after unmock");
    ok(!Issue55::UnmockInherited->meta->get_method('bar'),
        "inherited-orig: child meta no longer has bar after unmock");
}

done_testing;
