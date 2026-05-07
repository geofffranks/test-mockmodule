use warnings;
use strict;

use Test::More;
use Test::MockModule;
use Scalar::Util qw(refaddr);

package Tgt::SingletonOptIn; ## no critic (Modules::RequireFilenameMatchesPackage)
our $VERSION = 1;
sub greet { 'hello' }
package main; ## no critic (Modules::RequireFilenameMatchesPackage)

# 1. Default behavior unchanged: distinct objects per call (GH #48)
{
    my $a = Test::MockModule->new('Tgt::SingletonOptIn');
    my $b = Test::MockModule->new('Tgt::SingletonOptIn');
    isnt(refaddr($a), refaddr($b),
        'default new(): distinct objects (GH #48 preserved)');
}

# 2. singleton => 1: same object for same package
{
    my $a = Test::MockModule->new('Tgt::SingletonOptIn', singleton => 1);
    my $b = Test::MockModule->new('Tgt::SingletonOptIn', singleton => 1);
    is(refaddr($a), refaddr($b),
        'singleton => 1: same object across repeated new() calls');
}

# 3. singleton => 1 fixes the GH #83 reproducer pattern
{
    my @results;
    my $run = sub {
        my ($label) = @_;
        my $mock = Test::MockModule->new(
            'Tgt::SingletonOptIn', no_auto => 1, singleton => 1
        );
        $mock->mock('greet', sub {
            return $mock->original('greet')->() . "_$label";
        });
        push @results, Tgt::SingletonOptIn::greet();
    };
    $run->('first');
    $run->('second');
    is_deeply \@results, ['hello_first', 'hello_second'],
        'singleton => 1 fixes GH #83 reproducer';
}

# 4. singleton scope is per-package (different packages = different objects)
{
    package Other::SingletonOptIn;
    our $VERSION = 1;
    sub greet { 'other' }
    package main;

    my $a = Test::MockModule->new('Tgt::SingletonOptIn', singleton => 1);
    my $b = Test::MockModule->new('Other::SingletonOptIn', singleton => 1);
    isnt(refaddr($a), refaddr($b),
        'singleton scope is per-package');
}

# 5. singleton/non-singleton calls for the same package don't conflict
#    (non-singleton call always gets a fresh object)
{
    my $s = Test::MockModule->new('Tgt::SingletonOptIn', singleton => 1);
    my $d = Test::MockModule->new('Tgt::SingletonOptIn');
    isnt(refaddr($s), refaddr($d),
        'non-singleton new() always returns fresh object');

    my $s2 = Test::MockModule->new('Tgt::SingletonOptIn', singleton => 1);
    is(refaddr($s), refaddr($s2),
        'second singleton call returns the singleton');
}

# 6. _detect_self_capture warning is suppressed under singleton mode
{
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    package Tgt::SingletonNoWarn;
    our $VERSION = 1;
    sub greet { 'hi' }
    package main;

    my $mock = Test::MockModule->new(
        'Tgt::SingletonNoWarn', no_auto => 1, singleton => 1
    );
    $mock->mock('greet', sub {
        # Closure captures $mock -- would normally trigger GH #83 warning,
        # but singleton mode is the documented workaround so the warning
        # would be noise.
        return $mock->original('greet')->() . '_x';
    });
    is(scalar(@warnings), 0,
        'no GH #83 warning when singleton mode is used (documented workaround)')
        or diag explain \@warnings;
}

done_testing;
