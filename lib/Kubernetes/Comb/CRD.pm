package Kubernetes::Comb::CRD;
# ABSTRACT: IO::K8s resource map provider for the Comb custom resource
our $VERSION = '0.002';

use Moo;
with 'IO::K8s::Role::ResourceMap';

use Module::Runtime qw( use_module );
use Types::Standard qw( Str );
use Kubernetes::Comb::CRD::Comb;
use namespace::autoclean;

=synopsis

  use Kubernetes::REST;
  use Kubernetes::Comb::CRD;

  my $rest = Kubernetes::REST->new(
    server      => ...,
    credentials => ...,
    with        => [ 'Kubernetes::Comb::CRD' ]
  );
  my $combs = $rest->list('Comb', namespace => 'platform');

  # a CR class in another API group
  my $k8s = IO::K8s->new(
    with => [ Kubernetes::Comb::CRD->new(crd_class => 'MyApp::CRD::Comb') ]
  );

=description

Registers the Comb custom resource with L<IO::K8s>, so a client resolves the
Kind C<Comb> -- and its qualified name, C<comb.internal/v1/Comb> by default --
to the CR class and inflates Comb objects. Takes the place of the provider
classes IO::K8s ships for its bundled CRDs (C<IO::K8s::Cilium>, ...).

=cut

has crd_class => (
  is      => 'ro',
  isa     => Str,
  default => 'Kubernetes::Comb::CRD::Comb'
);

=attr crd_class

The CR class to register. Defaults to L<Kubernetes::Comb::CRD::Comb>; a
subclass for another API group goes here. Loaded on first use unless it is
already.

=cut

sub resource_map {
  my ( $self ) = @_;
  my $class = $self->crd_class;
  use_module($class) unless $class->can('kind');
  return {
    $class->kind                         => '+'.$class,
    $class->api_version.'/'.$class->kind => '+'.$class
  };
}

=method resource_map

Returns the map L<IO::K8s::Role::ResourceMap> asks for: the Kind and the
qualified C<apiVersion/Kind> of L</crd_class>, both pointing at the class. The
qualified entry is there for clients that take a plain C<resource_map> instead
of providers, like L<Net::Async::Kubernetes>.

=seealso

=over

=item * L<Kubernetes::Comb::CRD::Comb>

=item * L<IO::K8s/with>

=back

=cut

1;
