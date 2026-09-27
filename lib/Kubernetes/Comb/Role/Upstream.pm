package Kubernetes::Comb::Role::Upstream;
# ABSTRACT: What a Comb borrows its service from instead of running it
our $VERSION = '0.001';

use Moo::Role;

requires qw( status endpoints );

=synopsis

  package MyApp::Upstream::Catalog;
  use Moo;
  with 'Kubernetes::Comb::Role::Upstream';

  sub status    { ... }   # Future of { reachable => 1, phase => 'Running', via => [ ... ] }
  sub endpoints { ... }   # Future of [ Kubernetes::Comb::Endpoint, ... ]

  # in a Comb class, or returned by the upstream coderef of the controlling code
  sub upstream { '+MyApp::Upstream::Catalog' => ( url => 'https://catalog.example.com' ) }

=description

An upstream is where a Comb borrows its service from instead of running it
itself. L<Kubernetes::Comb/reconcile> accepts as upstream any object doing
this role, and builds one from the short forms (C<< K8s => (...) >>,
C<< '+Full::Class' => (...) >>) and from C<spec.upstream> of the custom
resource.

=method status

Future of a hashref: C<reachable>, C<phase>, C<via> (the layers the service
is borrowed through) and whatever else the upstream reports.

=method endpoints

Future of an arrayref of L<Kubernetes::Comb::Endpoint>, the addresses to use.

=method replicate_into

Optional. Called with the Comb to replicate data into it.

=seealso

=over

=item * L<Kubernetes::Comb>

=back

=cut

1;
