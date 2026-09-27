package Kubernetes::Comb::Endpoint;
# ABSTRACT: Value object for an endpoint a Comb offers
our $VERSION = '0.001';

use Moo;
use Types::Standard qw( Int Str );
use Kubernetes::Comb::CRD::CombEndpoint;
use namespace::autoclean;

=synopsis

  my $ep = Kubernetes::Comb::Endpoint->new(
    name     => 'client',
    port     => 4222,
    cluster  => 'nats.platform.svc:4222',
    external => 'nats.example.com:4222'
  );
  $ep->protocol;   # tcp

  my $status_entry = $ep->to_crd;                           # CombEndpoint
  my $again = Kubernetes::Comb::Endpoint->from_crd($status_entry);

=description

What a Comb offers under one name: protocol and port as the class declares
them, and the addresses it is reached at once resolved -- C<cluster> from
inside the cluster, C<external> from outside. With an active upstream both
point at the upstream. Immutable; a changed address is a new object.

=cut

has name => ( is => 'ro', isa => Str, required => 1 );

=attr name

Required. The name the Comb class declares the endpoint under, e.g. C<client>.

=cut

has protocol => ( is => 'ro', isa => Str, default => 'tcp' );

=attr protocol

Defaults to C<tcp>.

=cut

has port => ( is => 'ro', isa => Int, required => 1 );

=attr port

Required. The port the endpoint is offered on.

=cut

has cluster => ( is => 'ro', isa => Str, predicate => 1 );

=attr cluster

Optional. Address inside the cluster as C<host:port>; C<has_cluster> tells
whether there is one.

=cut

has external => ( is => 'ro', isa => Str, predicate => 1 );

=attr external

Optional. Address from outside the cluster as C<host:port>; C<has_external>
tells whether there is one.

=cut

sub crd_endpoint_class { 'Kubernetes::Comb::CRD::CombEndpoint' }

=method crd_endpoint_class

The status-entry class L</to_crd> builds, L<Kubernetes::Comb::CRD::CombEndpoint>.
Override it in a subclass to build another.

=cut

sub from_crd {
  my ( $class, $entry ) = @_;
  return $class->new(
    map { defined $entry->$_ ? ( $_ => $entry->$_ ) : () }
      qw( name protocol port cluster external )
  );
}

=method from_crd

  my $ep = Kubernetes::Comb::Endpoint->from_crd($combendpoint);

Builds an endpoint from a L<Kubernetes::Comb::CRD::CombEndpoint>, as found in
C<status.endpoints> of a Comb custom resource. A missing C<protocol> becomes
C<tcp>. Dies when C<name> or C<port> is missing.

=cut

sub to_crd {
  my ( $self ) = @_;
  return $self->crd_endpoint_class->new(
    name     => $self->name,
    protocol => $self->protocol,
    port     => $self->port,
    ( $self->has_cluster  ? ( cluster  => $self->cluster )  : () ),
    ( $self->has_external ? ( external => $self->external ) : () )
  );
}

=method to_crd

  $status->endpoints([ map { $_->to_crd } @endpoints ]);

Returns the endpoint as a L<Kubernetes::Comb::CRD::CombEndpoint> for
C<status.endpoints>.

=seealso

=over

=item * L<Kubernetes::Comb::CRD::CombEndpoint>

=back

=cut

1;
