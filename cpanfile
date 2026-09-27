requires 'Future';
requires 'IO::K8s', '1.108';
requires 'Kubernetes::REST', '1.108';
requires 'Module::Runtime';
requires 'Moo';

recommends 'Future::AsyncAwait';
recommends 'IO::Async';
recommends 'Net::Async::Kubernetes';

on test => sub {
  requires 'Test::More';
};
