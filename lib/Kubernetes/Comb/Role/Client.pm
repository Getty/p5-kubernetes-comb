package Kubernetes::Comb::Role::Client;
# ABSTRACT: The Kubernetes client surface a Comb works through
our $VERSION = '0.002';

use Moo::Role;

requires qw(
  get list ensure delete update patch update_status patch_status log
  server_url for_context
);

=synopsis

  package My::Client;
  use Moo;
  with 'Kubernetes::Comb::Role::Client';
  sub get { ... }   # and the rest of the surface

  # what a Comb does with any of them
  $comb->k8s->list('Pod', namespace => 'platform', labelSelector => 'app=nats')
    ->then(sub { my ( $list ) = @_; ... });

=description

The one seam between a Comb and Kubernetes. A Comb never talks to
L<Kubernetes::REST> or L<Net::Async::Kubernetes> directly; it calls these
methods on its C<k8s> client. L<Kubernetes::Comb::Client::Sync> and
L<Kubernetes::Comb::Client::Async> implement them, and so does the fake client
of the test suite, which is how that fake stays interchangeable with the real
ones.

The role only names the surface. Every request method returns a L<Future> and
never throws: a failure, including bad arguments, is a failed Future. Its
failure is the message the underlying client produced, for an API error
C<Kubernetes API error (E<lt>whatE<gt>): E<lt>statusE<gt> E<lt>bodyE<gt>>.
L</server_url> and L</for_context> are plain methods.

Resource names are what L<Kubernetes::REST> takes: a short Kind (C<'Pod'>), a
qualified C<'group/version/Kind'>, or C<'+Full::Class'> -- the last one needs
no resource map, which is how a Comb addresses its own CR class.

=cut

=method get

  my $f = $client->get('Deployment', 'nats', namespace => 'platform');

Future of the object.

=method list

  my $f = $client->list('Pod', namespace => 'platform', labelSelector => 'app=nats');

Future of an L<IO::K8s::List>; the objects are in C<< ->items >>. Without
C<namespace> it lists across all namespaces.

=method ensure

  my $f = $client->ensure($object_or_hashref);

Create or update. Future of the object as stored. C<status> is not written
this way -- see L</update_status>.

Two kinds are not updated once they exist, as C<ensure> of
L<Kubernetes::REST> and L<Net::Async::Kubernetes> has it: a C<v1>
PersistentVolumeClaim is returned as it is, and so is a C<batch/v1> Job that
runs or has succeeded (C<status.active>, C<status.succeeded>); any other
existing Job is deleted and created anew. A Comb relies on that: what is
left as it is never makes L<Kubernetes::Comb/reconcile> deploy by its
digest.

=method delete

  my $f = $client->delete('Service', 'nats', namespace => 'platform');
  my $f = $client->delete($object);
  my $f = $client->delete($job, propagationPolicy => 'Background');

Future of C<1>. C<propagationPolicy> (C<Background>, C<Foreground> or
C<Orphan>) decides what becomes of the objects the deleted one owns; without
it the API server orphans the Pods of a Job. Any other option fails the
Future.

=method update

  my $f = $client->update($object);

Full replacement (PUT) of the main resource. Future of the stored object.

=method patch

  my $f = $client->patch('Deployment', 'nats',
    namespace => 'platform',
    patch     => { spec => { replicas => 0 } },
    type      => 'strategic',   # or merge, json
  );
  my $f = $client->patch($object, patch => { ... });

Future of the patched object.

=method update_status

  my $f = $client->update_status($object);

Replaces C<status> through the status subresource; needs the current
C<resourceVersion>. Future of the stored object.

=method patch_status

  my $f = $client->patch_status($object, patch => { status => { phase => 'Running' } });

Merge patch (the default type) through the status subresource, no
C<resourceVersion> needed. Future of the stored object.

=method log

  my $f = $client->log('Pod', 'nats-0',
    namespace => 'platform',
    container => 'nats',
    previous  => 1,
    tailLines => 100
  );

Future of the log text.

=method server_url

  my $url = $client->server_url;

The API server URL of this client's context. Croaks when the context cannot
be resolved. Two clients whose URLs are equal talk to the same cluster.

=method for_context

  my $dev = $client->for_context('dev');

A client of the same class for another kube context from the same
kubeconfig, made once per context and kept --
L<Kubernetes::Comb::Upstream::K8s> asks for it on every step. Resolving the
context is deferred: a missing or broken context fails the first request's
Future, and makes L</server_url> croak.

=seealso

=over

=item * L<Kubernetes::Comb::Client::Sync>

=item * L<Kubernetes::Comb::Client::Async>

=back

=cut

1;
