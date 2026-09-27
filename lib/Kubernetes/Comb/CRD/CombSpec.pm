package Kubernetes::Comb::CRD::CombSpec;
# ABSTRACT: Spec of the Comb custom resource
our $VERSION = '0.001';

use IO::K8s::Resource;
use Carp qw( croak );

=synopsis

  my $spec = Kubernetes::Comb::CRD::CombSpec->new(
    class     => 'MyApp::Comb::NATS',
    dependsOn => [ 'db' ],
    config    => { cluster_size => 3 },
    upstream  => {
      class   => 'Kubernetes::Comb::Upstream::K8s',
      context => 'dev'
    }
  );

  # explicit "local": the key exists, its value is null
  my $local = Kubernetes::Comb::CRD::CombSpec->new(
    class    => 'MyApp::Comb::NATS',
    upstream => undef
  );
  $local->has_upstream;   # true
  $local->upstream;       # undef

=description

The C<spec> of a L<Kubernetes::Comb::CRD::Comb>, an L<IO::K8s> class like any
other with one addition: C<upstream> keeps the difference between a key that
is absent and a key that is present with C<null>. The upstream is resolved
from the first source that I<exists>, and an explicit C<upstream: null> in the
custom resource is the answer "local" that ends the lookup.

L<IO::K8s> drops a JSON C<null> on the way in and never writes one on the way
out -- C<nullable> is a schema-only option there. So this class inflates
itself through C<FROM_STRUCT>, the hook L<IO::K8s/struct_to_object> documents
for classes the generic path would lose data of, and adds the C<null> back in
C<TO_JSON>. The schema marks C<upstream> C<nullable>, so the API server keeps
the C<null> too.

=cut

k8s class => Str, {
  required    => 1,
  description => 'Perl class of the Comb; a stub is just another class'
};

=attr class

Required. The Perl class that implements the Comb. Pointing it at a stub class
selects the stub.

=cut

k8s dependsOn => [Str], {
  description => 'Combs this one needs, as "name" or "namespace/name"'
};

=attr dependsOn

ArrayRef of the Combs this one depends on, each C<name> or C<namespace/name>.

=cut

k8s config => { Str => 1 }, {
  preserve_unknown => 1,
  description      => 'Free-form configuration for the class'
};

=attr config

Free-form hashref for the Comb class. Never credentials.

=cut

k8s enabled => Bool, {
  description => 'Unset: automatic, false: off, true: on'
};

=attr enabled

Tri-state: C<undef> is automatic, false switches the Comb off, true on.

=cut

k8s upstream => { Str => 1 }, {
  nullable         => 1,
  preserve_unknown => 1,
  description      => 'Where the Comb borrows its service from: class plus'
    .' upstream-specific keys; null means local'
};

has '+upstream' => ( predicate => 1 );

=attr upstream

Hashref naming the upstream: C<class>, always the fully qualified class name,
plus the keys that class takes -- for L<Kubernetes::Comb::Upstream::K8s>
C<context>, C<namespace> and C<name>. C<undef> while L</has_upstream> is true
is the explicit "local".

=method has_upstream

True when the spec carries an C<upstream> key at all, an explicit C<null>
included. This, not the truth of L</upstream>, says whether the custom
resource has a say in the upstream resolution.

=cut

sub FROM_STRUCT {
  my ( $class, $struct ) = @_;
  croak $class.'->FROM_STRUCT needs a hashref, got '.( ref $struct || 'a plain scalar' )
    unless ref $struct eq 'HASH';
  my %args;
  for my $key ( keys %$struct ) {
    my $value = $struct->{$key};
    next unless defined $value || $key eq 'upstream';
    $args{$key} = ref $value eq 'HASH'  ? { %$value }
                : ref $value eq 'ARRAY' ? [ @$value ]
                : $value;
  }
  return $class->new(%args);
}

=method FROM_STRUCT

  my $spec = Kubernetes::Comb::CRD::CombSpec->FROM_STRUCT($hashref);

Called by L<IO::K8s> whenever a C<CombSpec> is built from a plain structure.
Behaves like the generic inflation -- a C<null> field counts as absent,
containers are copied one level -- except that C<upstream: null> is kept.
Croaks on anything but a hashref.

=cut

around TO_JSON => sub {
  my ( $orig, $self, @args ) = @_;
  my $data = $self->$orig(@args);
  $data->{upstream} = undef if $self->has_upstream && !defined $self->upstream;
  return $data;
};

=method TO_JSON

The inherited serialization, plus C<< upstream => undef >> (JSON C<null>) when
the spec holds the explicit "local".

=seealso

=over

=item * L<Kubernetes::Comb::CRD::Comb>

=back

=cut

1;
