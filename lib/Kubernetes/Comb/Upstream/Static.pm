package Kubernetes::Comb::Upstream::Static;
# ABSTRACT: An upstream with fixed endpoints and no cluster behind it
our $VERSION = '0.002';

use Moo;
with 'Kubernetes::Comb::Role::Upstream';

use Carp qw( croak );
use Future;
use Scalar::Util qw( blessed );
use Types::Standard qw( ArrayRef Bool InstanceOf Str );
use Kubernetes::Comb::Endpoint;
use namespace::autoclean;

=synopsis

  # a vendor service, from the controlling code or a class upstream method
  upstream => sub {
    Static => (
      endpoints => [ { name => 'api', port => 443, cluster => 'geoip.vendor.example:443' } ],
      via       => [ 'vendor' ]
    );
  }

  # the same in the custom resource
  upstream:
    class: Kubernetes::Comb::Upstream::Static
    endpoints:
      - { name: api, port: 443, cluster: geoip.vendor.example:443 }
    via: [ vendor ]

=description

An upstream whose endpoints are given, with nothing to ask: a vendor service,
a process or a Docker container running next to the cluster, or the upper
layers of a chain in a test. Its L</status> is whatever it was built with.

=cut

has _given => (
  is       => 'ro',
  isa      => ArrayRef,
  init_arg => 'endpoints',
  default  => sub { [] }
);

has _offered => (
  is       => 'lazy',
  isa      => ArrayRef[ InstanceOf['Kubernetes::Comb::Endpoint'] ],
  init_arg => undef
);

sub _build__offered {
  my ( $self ) = @_;
  return [ map {
    blessed $_ && $_->isa('Kubernetes::Comb::Endpoint') ? $_
      : ref $_ eq 'HASH' ? $self->endpoint_class->new(%$_)
      : croak ref($self).': an endpoint is a hashref or a Kubernetes::Comb::Endpoint, got '
        .( ref $_ || 'a plain scalar' );
  } @{ $self->_given } ];
}

=attr endpoints

Constructor argument: arrayref of what the upstream offers, each a
L<Kubernetes::Comb::Endpoint> or a hashref of its attributes (C<name>,
C<port>, C<protocol>, C<cluster>, C<external>). C<cluster> is the address to
use from inside the Comb's cluster; without it the Comb uses C<external>.
Default: none. Construction dies on an endpoint that is not one.

=cut

has phase => ( is => 'ro', isa => Str, default => 'Running' );

=attr phase

The phase L</status> reports, default C<Running>.

=cut

has via => ( is => 'ro', isa => ArrayRef[Str], default => sub { [] } );

=attr via

Arrayref of the layers L</status> reports, default none.

=cut

has reachable => ( is => 'ro', isa => Bool, coerce => 1, default => 1 );

=attr reachable

Whether L</status> reports the upstream reachable, default true.

=cut

has message => ( is => 'ro', isa => Str, predicate => 1 );

=attr message

Optional message L</status> reports.

=cut

sub BUILD { $_[0]->_offered }

sub endpoint_class { 'Kubernetes::Comb::Endpoint' }

=method endpoint_class

The class hashrefs in L</endpoints> become, L<Kubernetes::Comb::Endpoint>.

=cut

sub status {
  my ( $self, $comb ) = @_;
  return Future->done( {
    reachable => $self->reachable ? 1 : 0,
    phase     => $self->phase,
    via       => [ @{ $self->via } ],
    ( $self->has_message ? ( message => $self->message ) : () )
  } );
}

=method status

Future of C<< { reachable, phase, via, message } >> as built.

=cut

sub endpoints {
  my ( $self, $comb ) = @_;
  return Future->done( [ @{ $self->_offered } ] );
}

=method endpoints

Future of the arrayref of the L</endpoints> as L<Kubernetes::Comb::Endpoint>.

=seealso

=over

=item * L<Kubernetes::Comb::Role::Upstream>

=item * L<Kubernetes::Comb::Upstream::K8s>

=back

=cut

1;
