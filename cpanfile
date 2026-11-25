requires 'Future';
requires 'IO::K8s', '1.112';
requires 'JSON::MaybeXS';
requires 'Kubernetes::REST', '1.111';
requires 'Module::Runtime';
requires 'Moo';
requires 'namespace::autoclean';
requires 'Path::Tiny';
requires 'Types::Common::Numeric';
requires 'Types::Standard';
recommends 'Future::AsyncAwait';
recommends 'IO::Async';
recommends 'Net::Async::Kubernetes', '0.013';

on test => sub {
  requires 'Test::More';
};
