# Kubernetes::Comb

A self-contained "micro collection of Kubernetes parts" that runs as a live
Perl instance.

## Description

A Comb is one cell of a honeycomb: a named set of Kubernetes parts
(Deployments, Services, ConfigMaps, …) that deploys itself, reports its
status and publishes its endpoints. Controlling code builds the instance --
usually from a `Comb` custom resource -- and from then on only calls its
methods; all Kubernetes work happens inside the Comb class.

Combs can also be layered: one can borrow its service from another
environment (`getty -> dev -> prod`) instead of running it, or be replaced
by a small stub. Every lifecycle method returns a
[Future](https://metacpan.org/pod/Future) and never throws; `reconcile`
never even fails one. The dist ships no manager or daemon --
[examples/sync.pl](examples/sync.pl) and
[examples/async.pl](examples/async.pl) show what one looks like, driving
three Combs synchronously and with [IO::Async](https://metacpan.org/pod/IO::Async).

Full API documentation is in the module's own POD (`perldoc Kubernetes::Comb`
once installed, or [lib/Kubernetes/Comb.pm](lib/Kubernetes/Comb.pm) here);
the approved design is in [SPEC.md](SPEC.md).

## Synopsis

```perl
package MyApp::Comb::NATS;
use Moo;
extends 'Kubernetes::Comb';

sub endpoints { { name => 'client', port => 4222 } }

sub manifests {
  my ( $self ) = @_;
  return (
    { apiVersion => 'apps/v1', kind => 'Deployment', metadata => { name => 'nats' }, spec => { ... } },
    { apiVersion => 'v1',      kind => 'Service',    metadata => { name => 'nats' }, spec => { ... } }
  );
}

package main;

my $comb = Kubernetes::Comb->from_crd($cr,
  k8s      => $k8s,                             # default: Kubernetes::Comb::Client::Sync
  resolver => sub { $combs{ $_[0] } },
  stub     => sub { $_[0]->name eq 'mailer' }
);

$comb->deploy->get;
my $status = $comb->status->get;      # { phase => 'Running', healthy => 1, pods => [...] }
print $comb->logs(lines => 50)->get;
my $ep = $comb->endpoint('client')->get;
print $ep->cluster;                   # nats.platform.svc:4222
```

## Installation

```bash
cpanm Kubernetes::Comb
```

Async use (an `IO::Async`-driven manager, `Kubernetes::Comb::Client::Async`)
needs three optional dependencies, not installed by default:

```bash
cpanm IO::Async Net::Async::Kubernetes Future::AsyncAwait
```

## See Also

- [Kubernetes::REST](https://metacpan.org/pod/Kubernetes::REST) - the synchronous client this dist uses by default
- [Net::Async::Kubernetes](https://metacpan.org/pod/Net::Async::Kubernetes) - the async client behind `Kubernetes::Comb::Client::Async`
- [IO::K8s](https://metacpan.org/pod/IO::K8s) - the Kubernetes resource classes both clients use

## License

This software is copyright (c) 2026 by Torsten Raudssus.

This is free software; you can redistribute it and/or modify it under the
same terms as the Perl 5 programming language system itself.
