use inc::Module::Install;

name 'YAML-Perl';

all_from 'lib/YAML/Perl.pm';

requires 'Error';

clean_files 'pyyaml/lib/yaml/*.pyc';

WriteAll;