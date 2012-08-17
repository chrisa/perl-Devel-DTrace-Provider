use Test::More qw/ no_plan /;

BEGIN { use_ok Devel::DTrace::Provider; }

my $provider = Devel::DTrace::Provider->new('test0', 'test1module');
my $probe = $provider->probe('test', 'func', 'string', 'integer');
ok($provider->enable, 'Generate provider DOF');
ok($probe->fire('foo', 42));
