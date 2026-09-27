package Kubernetes::Comb::Client::Async;
# ABSTRACT: Asynchronous Comb client on Net::Async::Kubernetes
our $VERSION = '0.001';

use Moo;
with 'Kubernetes::Comb::Role::Client';

use Carp qw( croak );
use Future;
use IO::K8s;
use Module::Runtime qw( require_module );
use Types::Standard qw( InstanceOf Str );
use Kubernetes::Comb::CRD;
use namespace::autoclean;

# Optional dependencies (recommends): loaded here, not with `use`, so the
# rest of the distribution never needs them, and a missing one is named.
for my $module (qw( IO::Async::Loop Net::Async::Kubernetes )) {
  next if eval { require_module($module); 1 };
  croak __PACKAGE__.' needs '.$module.', an optional dependency of'
    .' Kubernetes::Comb that is not available: '.$@;
}

=synopsis

  use IO::Async::Loop;
  use Kubernetes::Comb::Client::Async;

  my $loop = IO::Async::Loop->new;
  my $k8s  = Kubernetes::Comb::Client::Async->new(loop => $loop, context => 'dev');
  my $k8s  = Kubernetes::Comb::Client::Async->new(kube => $kube);   # your own client

  $k8s->list('Pod', namespace => 'platform')->then(sub {
    my ( $list ) = @_;
    ...
  });

=description

The client of L<Kubernetes::Comb::Role::Client> for an L<IO::Async> program.
Every request goes through L<Net::Async::Kubernetes> and returns its
L<Future>; the loop runs the request. Where L<Net::Async::Kubernetes> croaks
instead of failing -- bad arguments to C<update>, C<update_status>, C<ensure>
-- the croak becomes a failed Future too.

L<IO::Async> and L<Net::Async::Kubernetes> are optional dependencies of
Kubernetes::Comb. Loading this module without them dies with a message naming
the missing one. The client needs L<Net::Async::Kubernetes> 0.009 for
C<ensure>, C<update_status> and C<patch_status>.

=cut

has kubeconfig => ( is => 'ro', isa => Str, predicate => 1 );

=attr kubeconfig

Path of the kubeconfig to read. Defaults to what L<Net::Async::Kubernetes>
finds: C<$KUBECONFIG>, then F<~/.kube/config>, then the in-cluster service
account.

=cut

has context => ( is => 'ro', isa => Str, predicate => 1 );

=attr context

Kube context to use. Defaults to the kubeconfig's current context.

=cut

has kube => (
  is        => 'lazy',
  isa       => InstanceOf['Net::Async::Kubernetes'],
  predicate => '_has_kube'
);

sub _build_kube {
  my ( $self ) = @_;
  my $kube = Net::Async::Kubernetes->new(
    ( $self->has_kubeconfig ? ( kubeconfig => $self->kubeconfig ) : () ),
    ( $self->has_context    ? ( context    => $self->context )    : () ),
    resource_map => {
      %{ IO::K8s->default_resource_map },
      %{ Kubernetes::Comb::CRD->new->resource_map }
    }
  );
  $self->loop->add($kube);
  return $kube;
}

=attr kube

The L<Net::Async::Kubernetes> instance. Built on first use from
L</kubeconfig> and L</context>, with the Comb custom resource in its resource
map, and added to L</loop>. A failure building it fails the Future of the
request that needed it. One you pass yourself must already be added to a
loop.

=cut

has loop => ( is => 'lazy', isa => InstanceOf['IO::Async::Loop'] );

sub _build_loop {
  my ( $self ) = @_;
  return $self->kube->loop if $self->_has_kube && $self->kube->loop;
  return IO::Async::Loop->new;
}

=attr loop

The L<IO::Async::Loop>. Defaults to the loop a passed L</kube> is in, else
to C<< IO::Async::Loop->new >>, the process-wide loop.

=cut

sub get           { shift->_call( get           => @_ ) }
sub list          { shift->_call( list          => @_ ) }
sub ensure        { shift->_call( ensure        => @_ ) }
sub delete        { shift->_call( delete        => @_ ) }
sub update        { shift->_call( update        => @_ ) }
sub patch         { shift->_call( patch         => @_ ) }
sub update_status { shift->_call( update_status => @_ ) }
sub patch_status  { shift->_call( patch_status  => @_ ) }
sub log           { shift->_call( log           => @_ ) }

sub _call {
  my ( $self, $method, @args ) = @_;
  return Future->call( sub { $self->kube->$method(@args) } );
}

=method get

=method list

=method ensure

=method delete

=method update

=method patch

=method update_status

=method patch_status

=method log

The request methods of L<Kubernetes::Comb::Role::Client>, each passing its
arguments to the L<Net::Async::Kubernetes> method of the same name and
returning its L<Future>.

=cut

sub server_url { shift->kube->server->endpoint }

=method server_url

The API server URL of L</kube>.

=cut

has _for_context => ( is => 'ro', init_arg => undef, default => sub { {} } );

sub for_context {
  my ( $self, $context ) = @_;
  return $self->_for_context->{$context} //= ref($self)->new(
    loop => $self->loop,
    ( $self->has_kubeconfig ? ( kubeconfig => $self->kubeconfig ) : () ),
    context => $context
  );
}

=method for_context

  my $dev = $k8s->for_context('dev');

The client on the same L</loop> for another context of the same
L</kubeconfig> (the default one when none was given), made on first use and
kept: asking again returns the same one, so the loop gets one more
L<Net::Async::Kubernetes> per context, not per call. Nothing is read until
its first request.

=seealso

=over

=item * L<Kubernetes::Comb::Role::Client>

=item * L<Kubernetes::Comb::Client::Sync>

=back

=cut

1;
