use ExtUtils::MakeMaker;

my $build_output = `cd libusdt && make clean all && cd ..`;
print $build_output;

# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile(
    NAME          => 'Devel::DTrace::Provider',
    VERSION_FROM  => 'lib/Devel/DTrace/Provider.pm',
    ABSTRACT_FROM => 'lib/Devel/DTrace/Provider.pm',
    AUTHOR        => 'Chris Andrews <chris@nodnol.org>',
    LIBS          => ['-Llibusdt -lusdt'],
    INC           => '-I. -Ilibusdt',
);
