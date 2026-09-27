requires 'Future';
requires 'IO::K8s', '1.108';
requires 'Kubernetes::REST', '1.108';
requires 'Module::Runtime';
requires 'Moo';
requires 'namespace::autoclean';
requires 'Types::Standard';

recommends 'Future::AsyncAwait';
recommends 'IO::Async';
recommends 'Net::Async::Kubernetes';

on test => sub {
  requires 'JSON::MaybeXS';
  requires 'Test::More';
};
