use inc::Module::Install;

name 'YAML-Perl';

all_from 'lib/YAML/Perl.pm';

requires 'Error';

use_test_base;

clean_files 'pyyaml/lib/yaml/*.pyc';

WriteAll;
