package TestComb::Fixtures;
# Builders for the canned objects of the Comb unit tests. Plain POD: t/lib is
# not woven.

use strict;
use warnings;

use Exporter 'import';
use Kubernetes::Comb::CRD::Comb;

our @EXPORT_OK = qw( comb_cr comb_labels pod set_status );

=head1 FUNCTIONS

=head2 comb_labels

  my %labels = comb_labels('nats');

The labels a Comb of that name puts on its resources, with the default
prefix and managed-by value.

=cut

sub comb_labels {
  my ( $name ) = @_;
  return (
    'comb.internal/comb'           => $name,
    'app.kubernetes.io/managed-by' => 'kubernetes-comb'
  );
}

=head2 comb_cr

  my $cr = comb_cr(name => 'nats', class => 'TestComb::NATS', spec => { ... });

A L<Kubernetes::Comb::CRD::Comb> in namespace C<platform> (or C<namespace>),
with C<spec.class> and whatever else C<spec> holds.

=cut

sub comb_cr {
  my ( %args ) = @_;
  return Kubernetes::Comb::CRD::Comb->new(
    metadata => { name => $args{name}, namespace => $args{namespace} // 'platform' },
    spec     => { class => $args{class}, %{ $args{spec} // {} } }
  );
}

=head2 pod

  my $manifest = pod('nats-0',
    comb       => 'nats',                  # labels, default nats
    phase      => 'Running',
    containers => [ { name => 'nats', ready => 1, restartCount => 2, state => { ... } } ],
    init       => [ ... ],                 # initContainerStatuses
    conditions => [ { type => 'PodScheduled', status => 'False', ... } ],
    owner      => 'ReplicaSet',            # an ownerReference of that kind
    reason     => 'Evicted',
    message    => '...'
  );

A Pod manifest in namespace C<platform> carrying the Comb labels. Its
C<spec.containers> follow the names in C<containers> (default one named
C<main>, ready and running).

=cut

sub pod {
  my ( $name, %args ) = @_;
  my @containers = @{ $args{containers} // [ { name => 'main', ready => 1, state => { running => {} } } ] };
  return {
    apiVersion => 'v1',
    kind       => 'Pod',
    metadata   => {
      name      => $name,
      namespace => $args{namespace} // 'platform',
      labels    => { comb_labels( $args{comb} // 'nats' ) },
      ( $args{owner}
        ? ( ownerReferences => [ { apiVersion => 'apps/v1', kind => $args{owner}, name => 'owner', uid => 'u-1' } ] )
        : () )
    },
    spec   => { containers => [ map { +{ name => $_->{name}, image => 'img' } } @containers ] },
    status => {
      phase             => $args{phase} // 'Running',
      containerStatuses => [ map { +{
        image        => 'img',
        imageID      => '',
        %$_,
        ready        => $_->{ready} ? \1 : \0,
        restartCount => $_->{restartCount} // 0
      } } @containers ],
      ( $args{init}       ? ( initContainerStatuses => [ map { +{ image => 'img', imageID => '', ready => \0, restartCount => 0, %$_ } } @{ $args{init} } ] ) : () ),
      ( $args{conditions} ? ( conditions => $args{conditions} ) : () ),
      ( $args{reason}     ? ( reason     => $args{reason} )     : () ),
      ( $args{message}    ? ( message    => $args{message} )    : () )
    }
  };
}

=head2 set_status

  set_status($k8s, Deployment => 'nats', { readyReplicas => 1 }, namespace => 'platform');

Replaces the C<status> of a stored object, the way a controller would.

=cut

sub set_status {
  my ( $k8s, $kind, $name, $status, %args ) = @_;
  my $object = $k8s->object( $kind, $name, namespace => $args{namespace} // 'platform' )
    or die "set_status: no $kind $name stored";
  $k8s->add( { %{ $object->TO_JSON }, status => $status } );
  return;
}

1;
