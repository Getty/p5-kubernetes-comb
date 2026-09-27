use strict;
use warnings;
use Test::More;

use lib 't/lib';
use Kubernetes::Comb;
use Kubernetes::Comb::Client::Fake;
use Kubernetes::Comb::CRD::CombStatus;
use TestComb::Configurable;
use TestComb::Fixtures qw( comb_labels deployment service set_status );

my %labels = comb_labels('nats');

my %deployment_nats = ( apiVersion => 'apps/v1', kind => 'Deployment', namespace => 'platform', name => 'nats' );

# nats, rendering one Deployment, with what an earlier step recorded.
sub comb {
  my ( @recorded ) = @_;
  my $k8s = Kubernetes::Comb::Client::Fake->new;
  my $comb = TestComb::Configurable->new(
    name      => 'nats',
    namespace => 'platform',
    k8s       => $k8s,
    parts     => [ deployment('nats') ]
  );
  $comb->_memory_status( Kubernetes::Comb::CRD::CombStatus->new(
    phase            => 'Pending',
    managedResources => [ {%deployment_nats}, @recorded ]
  ) );
  return ( $comb, $k8s );
}

sub managed {
  my ( $status ) = @_;
  return [ map { $_->TO_JSON } @{ $status->managedResources // [] } ];
}

sub ready_message {
  my ( $status ) = @_;
  my ( $ready ) = grep { $_->type eq 'Ready' } @{ $status->conditions };
  return $ready->message;
}

sub deleted {
  my ( $k8s ) = @_;
  return [ map { $_->[0]->kind.'/'.$_->[0]->metadata->name } $k8s->calls_of('delete') ];
}

subtest 'an orphan that carries the label is deleted' => sub {
  my %old = ( apiVersion => 'v1', kind => 'Service', namespace => 'platform', name => 'old' );
  my ( $comb, $k8s ) = comb( {%old} );
  $k8s->add( service( 'old', namespace => 'platform', labels => {%labels} ) );

  my $status = $comb->reconcile->get;
  is $status->phase, 'Pending', 'Pending';
  is_deeply deleted($k8s), [ 'Service/old' ], 'deleted';
  ok !$k8s->object( Service => 'old', namespace => 'platform' ), 'gone from the cluster';
  is_deeply managed($status), [ {%deployment_nats} ], 'and from managedResources';
  unlike ready_message($status), qr/old/, 'nothing to report';
};

subtest 'an orphan without the label is never deleted' => sub {
  my %shared = ( apiVersion => 'v1', kind => 'Service', namespace => 'platform', name => 'shared' );
  my %taken  = ( apiVersion => 'v1', kind => 'Service', namespace => 'platform', name => 'taken' );
  my ( $comb, $k8s ) = comb( {%shared}, {%taken} );
  $k8s->add(
    service( 'shared', namespace => 'platform' ),
    service( 'taken', namespace => 'platform', labels => { comb_labels('other') } )
  );

  my $status = $comb->reconcile->get;
  is_deeply deleted($k8s), [], 'nothing deleted';
  ok $k8s->object( Service => $_, namespace => 'platform' ), $_.' is still there' for qw( shared taken );
  is_deeply managed($status), [ {%deployment_nats} ], 'dropped from managedResources';
  like ready_message($status), qr/left Service shared alone: it no longer carries comb\.internal\/comb=nats/,
    'reported: label gone';
  like ready_message($status), qr/left Service taken alone/, 'reported: another Comb\'s';
};

subtest 'an orphan that is already gone is dropped' => sub {
  my %gone = ( apiVersion => 'v1', kind => 'Secret', namespace => 'platform', name => 'gone' );
  my ( $comb, $k8s ) = comb( {%gone} );
  my $status = $comb->reconcile->get;
  is_deeply deleted($k8s), [], 'nothing to delete';
  is_deeply managed($status), [ {%deployment_nats} ], 'dropped from managedResources';
  unlike ready_message($status), qr/gone/, 'nothing to report';
};

subtest 'a new API version is no orphan' => sub {
  my $k8s = Kubernetes::Comb::Client::Fake->new;
  my $comb = TestComb::Configurable->new(
    name      => 'nats',
    namespace => 'platform',
    k8s       => $k8s,
    parts     => [ deployment('nats') ]
  );
  $comb->_memory_status( Kubernetes::Comb::CRD::CombStatus->new(
    phase            => 'Pending',
    managedResources => [ { %deployment_nats, apiVersion => 'apps/v1beta1' } ]
  ) );
  my $status = $comb->reconcile->get;
  is_deeply deleted($k8s), [], 'nothing deleted';
  ok !grep( { $_->[0] =~ /v1beta1/ } $k8s->calls_of('list') ), 'not even looked for';
  is_deeply managed($status), [ {%deployment_nats} ], 'recorded under the version applied now';
};

subtest 'a failed delete stays for the next step' => sub {
  my %old = ( apiVersion => 'v1', kind => 'Service', namespace => 'platform', name => 'old' );
  my ( $comb, $k8s ) = comb( {%old} );
  $k8s->add( service( 'old', namespace => 'platform', labels => {%labels} ) );
  $k8s->fail_on( delete => 'forbidden', times => 1 );

  my $status = $comb->reconcile->get;
  is $status->phase, 'Pending', 'still Pending';
  is_deeply managed($status), [ {%deployment_nats}, {%old} ], 'kept in managedResources';
  like ready_message($status), qr/deleting Service old failed: forbidden/, 'reported';
  ok $k8s->object( Service => 'old', namespace => 'platform' ), 'still there';

  $status = $comb->reconcile->get;
  ok !$k8s->object( Service => 'old', namespace => 'platform' ), 'the next deploy deletes it';
  is_deeply managed($status), [ {%deployment_nats} ], 'and drops it';
};

subtest 'an orphan that cannot be checked stays' => sub {
  my %old = ( apiVersion => 'v1', kind => 'Service', namespace => 'platform', name => 'old' );
  my ( $comb, $k8s ) = comb( {%old} );
  $k8s->add( service( 'old', namespace => 'platform', labels => {%labels} ) );
  $k8s->fail_on( list => 'connection reset', when => sub { $_[0] eq 'v1/Service' } );

  my $status = $comb->reconcile->get;
  is_deeply deleted($k8s), [], 'nothing deleted';
  is_deeply managed($status), [ {%deployment_nats}, {%old} ], 'kept in managedResources';
  like ready_message($status), qr/could not check Service old for pruning: connection reset/, 'reported';
};

subtest 'a cluster-scoped orphan' => sub {
  my %role = ( apiVersion => 'rbac.authorization.k8s.io/v1', kind => 'ClusterRole', name => 'nats-reader' );
  my ( $comb, $k8s ) = comb( {%role} );
  $k8s->add( {
    apiVersion => 'rbac.authorization.k8s.io/v1',
    kind       => 'ClusterRole',
    metadata   => { name => 'nats-reader', labels => {%labels} },
    rules      => []
  } );
  my $status = $comb->reconcile->get;
  is_deeply deleted($k8s), [ 'ClusterRole/nats-reader' ], 'deleted';
  my ( $list ) = grep { $_->[0] =~ /ClusterRole/ } $k8s->calls_of('list');
  ok !{ @{$list}[ 1 .. $#$list ] }->{namespace}, 'looked for without a namespace';
  is_deeply managed($status), [ {%deployment_nats} ], 'dropped';
};

subtest 'no pruning without a deploy' => sub {
  my %old = ( apiVersion => 'v1', kind => 'Service', namespace => 'platform', name => 'old' );
  my ( $comb, $k8s ) = comb( {%old} );
  $k8s->add( service( 'old', namespace => 'platform', labels => {%labels} ) );
  $comb->deploy->get;
  set_status( $k8s, Deployment => 'nats', { readyReplicas => 1 } );

  my $status = $comb->reconcile->get;
  is $status->phase, 'Running', 'healthy: Running';
  is_deeply deleted($k8s), [], 'nothing pruned';
  is_deeply managed($status), [ {%deployment_nats}, {%old} ], 'the orphan stays recorded';
};

subtest 'a resource the manifests drop is pruned' => sub {
  my %web = ( apiVersion => 'v1', kind => 'Service', namespace => 'platform', name => 'nats' );
  my ( $comb, $k8s ) = comb();
  $comb->parts( [ deployment('nats'), service('nats') ] );
  my $status = $comb->reconcile->get;
  is_deeply managed($status), [ {%deployment_nats}, {%web} ], 'recorded';
  $k8s->clear_calls;

  $comb->parts( [ deployment('nats') ] );
  $status = $comb->reconcile->get;
  is_deeply deleted($k8s), [ 'Service/nats' ], 'dropped from the manifests: deleted';
  is_deeply managed($status), [ {%deployment_nats} ], 'and no longer recorded';
};

done_testing;
