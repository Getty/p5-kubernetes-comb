package Kubernetes::Comb;
# ABSTRACT: A self-contained micro collection of Kubernetes parts as a live Perl instance
our $VERSION = '0.001';

use Moo;

use Carp qw( croak );
use Future;
use Future::Utils qw( fmap_void );
use IO::K8s;
use JSON::MaybeXS qw( JSON );
use Module::Runtime qw( use_module use_package_optimistically );
use POSIX qw( strftime );
use Scalar::Util qw( blessed );
use Types::Standard qw( ArrayRef CodeRef ConsumerOf HashRef InstanceOf Maybe Object Str );
use Kubernetes::Comb::CRD;
use Kubernetes::Comb::CRD::Comb;
use Kubernetes::Comb::Client::Sync;
use Kubernetes::Comb::Endpoint;
use namespace::autoclean;

=synopsis

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

=description

A Comb is one cell of a honeycomb: a named set of Kubernetes parts that
deploys itself, reports its status and publishes its endpoints. Controlling
code builds the instance -- usually with L</from_crd> from a C<Comb> custom
resource -- and from then on only calls its methods. All Kubernetes work
happens in here, through the L</k8s> client.

A Comb class extends this one and overrides the contract: L</name>,
L</depends_on>, L</endpoints>, L</manifests>, L</check>,
L</bridge_manifests>, L</stub_class>. It may also define a plain C<upstream>
method (where its service is borrowed from); this class deliberately defines
none, so whether a class has one is visible to C<can>.

Every lifecycle method -- L</deploy>, L</status>, L</healthy>, L</logs>,
L</restart>, L</stop>, L</describe>, L</endpoint> -- returns a L<Future> and
never throws: any error, including one in a contract method, is a failed
Future.

=cut

# group/Kind of the workloads, each with the paths below the object where it
# keeps the templates of what it creates. The Comb labels go there too, so
# the Pods (and a CronJob's Jobs) carry them. [] would be the object itself,
# which is always labelled; a bare Pod has nothing else.
my %WORKLOAD_TEMPLATES = (
  '/Pod'                   => [],
  '/ReplicationController' => [ [qw( spec template )] ],
  'apps/Deployment'        => [ [qw( spec template )] ],
  'apps/StatefulSet'       => [ [qw( spec template )] ],
  'apps/DaemonSet'         => [ [qw( spec template )] ],
  'apps/ReplicaSet'        => [ [qw( spec template )] ],
  'batch/Job'              => [ [qw( spec template )] ],
  'batch/CronJob'          => [ [qw( spec jobTemplate )], [qw( spec jobTemplate spec template )] ]
);

# Workloads that report ready replicas against spec.replicas.
my %REPLICATED = map { $_ => 1 } qw(
  /ReplicationController apps/Deployment apps/StatefulSet apps/ReplicaSet
);

# Container waiting reasons that do not go away by waiting.
my %FAILURE_REASONS = map { $_ => 1 } qw(
  CrashLoopBackOff ImagePullBackOff ErrImagePull ErrImageNeverPull InvalidImageName
  CreateContainerConfigError CreateContainerError RunContainerError
);

my %ENDPOINT_KEYS = map { $_ => 1 } qw( name port protocol service cluster external );

####
#### Attributes
####

has k8s => (
  is  => 'lazy',
  isa => ConsumerOf['Kubernetes::Comb::Role::Client']
);

sub _build_k8s { Kubernetes::Comb::Client::Sync->new }

=attr k8s

The Kubernetes client, anything doing L<Kubernetes::Comb::Role::Client>.
Defaults to a L<Kubernetes::Comb::Client::Sync> on the current kube context;
pass a L<Kubernetes::Comb::Client::Async> to run on an L<IO::Async> loop.

=cut

has resolver => ( is => 'ro', isa => CodeRef, predicate => 1 );

=attr resolver

Coderef that turns a dependency reference (C<name> or C<namespace/name>) into
the Comb instance. The only way a Comb finds its dependencies; supplied by the
controlling code. C<has_resolver> tells whether there is one.

=cut

# init_arg upstream, but no `upstream` reader: a Comb class may define a plain
# `upstream` method (SPEC §5, source 3), and whether it does must stay visible
# to can().
has _upstream => (
  is        => 'ro',
  isa       => Maybe[ CodeRef | HashRef | ArrayRef | Object ],
  init_arg  => 'upstream',
  predicate => 1
);

=attr upstream

Constructor argument: what the controlling code says about the upstream, the
first source of the upstream resolution. A coderef, called with the Comb and
returning what a class C<upstream> method returns; or that answer given
directly: an object doing C<Kubernetes::Comb::Role::Upstream>, a hashref as in
the custom resource (C<< { class => ..., ... } >>), an arrayref of the Perl
helper form (C<< [ K8s => ( context => 'dev' ) ] >>), or C<undef> for an
explicit "local". There is no reader of this name.

=cut

has crd => (
  is        => 'rwp',
  isa       => InstanceOf['Kubernetes::Comb::CRD::Comb'],
  predicate => 1
);

=attr crd

The C<Comb> custom resource this instance was built from, if any. Name,
namespace, config and dependencies default to what it says, and the Comb
writes its status into it. C<has_crd> tells whether there is one.

=cut

has crd_class => ( is => 'lazy', isa => Str, predicate => '_has_crd_class' );

sub _build_crd_class {
  my ( $self ) = @_;
  return $self->has_crd ? ref $self->crd : 'Kubernetes::Comb::CRD::Comb';
}

=attr crd_class

The custom resource class. Defaults to the class of L</crd>, else
L<Kubernetes::Comb::CRD::Comb>. A CR class for another API group is a
subclass of that, see L<Kubernetes::Comb::CRD::Comb>. Construction dies when a
given L</crd> is not an instance of it.

=cut

has namespace => ( is => 'lazy', isa => Str );

sub _build_namespace {
  my ( $self ) = @_;
  my $meta = $self->has_crd ? $self->crd->metadata : undef;
  my $namespace = $meta ? $meta->namespace : undef;
  croak ref($self).' has no namespace: pass namespace, or a crd with metadata.namespace'
    unless defined $namespace && length $namespace;
  return $namespace;
}

=attr namespace

Where the Comb lives: its namespaced resources that name none get this one.
Defaults to the namespace of L</crd>; without either, every operation that
needs it fails.

=cut

has config => ( is => 'lazy', isa => HashRef );

sub _build_config {
  my ( $self ) = @_;
  my $spec = $self->has_crd ? $self->crd->spec : undef;
  return $spec && $spec->config ? { %{ $spec->config } } : {};
}

=attr config

Free-form configuration for the class. Defaults to a copy of C<spec.config>
of L</crd>, else an empty hashref.

=cut

has label_prefix => ( is => 'ro', isa => Str, default => 'comb.internal/' );

=attr label_prefix

Prefix of the label and annotation keys the Comb sets, default
C<comb.internal/>: the name label is C<E<lt>prefixE<gt>comb>, the restart
annotation C<E<lt>prefixE<gt>restartedAt>. Include the trailing C</>.

=cut

has managed_by => ( is => 'ro', isa => Str, default => 'kubernetes-comb' );

=attr managed_by

Value of the C<app.kubernetes.io/managed-by> label on every resource the Comb
deploys. Default C<kubernetes-comb>.

=cut

has io_k8s => ( is => 'lazy', isa => InstanceOf['IO::K8s'] );

sub _build_io_k8s {
  my ( $self ) = @_;
  return IO::K8s->new( with => [ Kubernetes::Comb::CRD->new( crd_class => $self->crd_class ) ] );
}

=attr io_k8s

The L<IO::K8s> instance that tells the Comb what a manifest hashref is:
whether its Kind is namespaced, and its C<apiVersion> when it has none.
Defaults to one that knows the built-in Kinds and the Comb CR. Pass one with
your CRD providers (C<< IO::K8s->new(with => [...]) >>) when manifests
contain cluster-scoped custom resources; a Kind it does not know counts as
namespaced.

=cut

has stub_of => (
  is        => 'ro',
  isa       => InstanceOf['Kubernetes::Comb'],
  predicate => 'is_stub'
);

=attr stub_of

The original Comb this instance stands in for, when it was built as its stub
(see L</from_crd>). Construction checks the contract: a stub that lacks any
endpoint name of its original dies, naming the missing ones. C<is_stub> tells
whether there is one.

=cut

# The recorded status without a CR (with one it is crd->status).
has _memory_status => (
  is       => 'rw',
  isa      => Maybe[ InstanceOf['Kubernetes::Comb::CRD::CombStatus'] ],
  init_arg => undef
);

sub BUILD {
  my ( $self ) = @_;
  croak ref($self).': crd is a '.ref( $self->crd ).', not a '.$self->crd_class
    if $self->has_crd && $self->_has_crd_class && !$self->crd->isa( $self->crd_class );
  $self->_check_stub_contract if $self->is_stub;
}

sub _check_stub_contract {
  my ( $self ) = @_;
  my %own = map { $_ => 1 } $self->_endpoint_names;
  my @missing = grep { !$own{$_} } $self->stub_of->_endpoint_names;
  croak ref($self).' does not keep the contract of '.ref( $self->stub_of )
    .': missing endpoint(s) '.join( ', ', @missing ) if @missing;
}

####
#### Contract
####

sub name {
  my ( $self ) = @_;
  my $meta = $self->has_crd ? $self->crd->metadata : undef;
  return $meta->name if $meta && defined $meta->name && length $meta->name;
  croak ref($self).' has no name: override name, or build it from a Comb custom resource';
}

=method name

The name of the Comb. Defaults to C<metadata.name> of L</crd>; a class used
without a custom resource overrides it.

=cut

sub depends_on {
  my ( $self ) = @_;
  my $spec = $self->has_crd ? $self->crd->spec : undef;
  return $spec ? @{ $spec->dependsOn // [] } : ();
}

=method depends_on

List of the Combs this one needs, each C<name> or C<namespace/name>.
Defaults to C<spec.dependsOn> of L</crd>.

=cut

sub endpoints { return }

=method endpoints

List of what the Comb offers, each a hashref or a L<Kubernetes::Comb::Endpoint>.
A hashref has C<name> and C<port>, optionally C<protocol> (default C<tcp>),
C<service> (the Service it is reached through, default L</name>),
C<external> and C<cluster> (both C<host:port>; C<cluster> defaults to
C<E<lt>serviceE<gt>.E<lt>namespaceE<gt>.svc:E<lt>portE<gt>>). Default: none.

=cut

sub manifests { return }

=method manifests

List of the resources the Comb consists of, as L<IO::K8s> objects or
hashrefs -- or a Future of that list. Default: none.

=cut

sub check { return }

=method check

List of the prerequisites that are missing, as human-readable strings -- or a
Future of that list. Empty means the Comb can go ahead. Default: nothing
missing.

=cut

sub bridge_manifests { return }

=method bridge_manifests

  my @manifests = $comb->bridge_manifests(@upstream_endpoints);

The resources that make the upstream reachable under the local names while an
upstream is active. Default: none yet.

=cut

sub stub_class {
  my ( $self ) = @_;
  my $stub = ( ref $self || $self ).'::Stub';
  use_package_optimistically($stub) unless $stub->can('new');
  return $stub->can('new') ? $stub : undef;
}

=method stub_class

The class that stands in for this one when a stub is asked for. Defaults to
C<E<lt>classE<gt>::Stub> if that class exists or loads -- a stub that fails to
compile dies --, else C<undef>. Works as class and as instance method.

=cut

sub endpoint_class { 'Kubernetes::Comb::Endpoint' }

=method endpoint_class

The class L</endpoint> builds, L<Kubernetes::Comb::Endpoint>.

=cut

####
#### Construction from the CR
####

sub from_crd {
  my ( $self, $crd, %opts ) = @_;
  my $base = ref $self || $self;
  croak $base.'->from_crd needs a Comb custom resource object'
    unless blessed $crd && $crd->isa('Kubernetes::Comb::CRD::Comb');
  croak $base.'->from_crd: the custom resource has no spec.class'
    unless $crd->spec && $crd->spec->class;
  my $stub = delete $opts{stub};
  croak $base.'->from_crd: stub must be a coderef' if defined $stub && ref $stub ne 'CODE';

  my $class = $self->_load_comb_class( $crd->spec->class, $base );
  my $comb  = $class->new( %opts, crd => $crd );
  return $comb unless $stub && $stub->($comb);

  my $stub_class = $comb->stub_class;
  croak $base.'->from_crd: a stub was asked for '.$comb->name.', but '.$class.' has no stub class'
    unless defined $stub_class;
  return $self->_load_comb_class( $stub_class, __PACKAGE__ )
    ->new( %opts, crd => $crd, stub_of => $comb );
}

=method from_crd

  my $comb = Kubernetes::Comb->from_crd($cr,
    k8s      => $k8s,
    resolver => sub { ... },
    upstream => sub { ... },
    stub     => sub { my ( $comb ) = @_; ... }
  );

Builds the Comb for a C<Comb> custom resource: loads C<spec.class> and
constructs it with C<< crd => $cr >> plus the options, all of which but
C<stub> go to the constructor. C<stub> is called with that instance; when it
returns true, the instance's L</stub_class> is built instead, with the
original as L</stub_of> -- which checks the stub keeps the original's
endpoints. Dies when C<spec.class> is not a subclass of the invocant, or a
stub is asked for and there is none.

=cut

sub _load_comb_class {
  my ( $self, $class, $base ) = @_;
  use_module($class) unless $class->can('new');
  croak( ( ref $self || $self ).'->from_crd: '.$class.' is not a '.$base )
    unless $class->isa($base);
  return $class;
}

####
#### Labels
####

sub comb_label { shift->label_prefix.'comb' }

=method comb_label

Key of the label that carries the Comb name: C<E<lt>label_prefixE<gt>comb>.

=cut

sub comb_labels {
  my ( $self ) = @_;
  return {
    $self->comb_label              => $self->name,
    'app.kubernetes.io/managed-by' => $self->managed_by
  };
}

=method comb_labels

Hashref of the labels every resource of the Comb gets, Pod templates of its
workloads included: L</comb_label> with the name, and
C<app.kubernetes.io/managed-by> with L</managed_by>.

=cut

sub label_selector {
  my ( $self ) = @_;
  return $self->comb_label.'='.$self->name;
}

=method label_selector

Label selector for everything of this Comb, C<E<lt>comb_labelE<gt>=E<lt>nameE<gt>>.

=cut

sub restart_annotation { shift->label_prefix.'restartedAt' }

=method restart_annotation

Pod template annotation L</restart> sets: C<E<lt>label_prefixE<gt>restartedAt>.

=cut

####
#### Lifecycle
####

sub deploy {
  my ( $self ) = @_;
  return Future->call( sub {
    $self->_render->then( sub { $self->_apply(@_) } );
  } );
}

=method deploy

  my @stored = $comb->deploy->get;

Renders L</manifests>, labels every resource (and the Pod templates of
workloads) with L</comb_labels>, puts L</namespace> on namespaced resources
that name none, and creates or updates them one after the other. Future of
the objects as stored. A failure stops at that resource; the Future fails
with the message, category C<deploy> and C<< { applied => [...], failed => $manifest } >>.

=cut

sub status {
  my ( $self ) = @_;
  return Future->call( sub {
    $self->_render->then( sub {
      my @items = @_;
      return Future->done( $self->_status_of( \@items, [] ) ) unless @items;
      return $self->_fetch_live(@items)->then( sub {
        return Future->done( $self->_status_of( \@items, [] ) )
          unless grep { $_->{workload} && $_->{live} } @items;
        return $self->_pods->then( sub { Future->done( $self->_status_of( \@items, [@_] ) ) } );
      } );
    } );
  } );
}

=method status

  my $status = $comb->status->get;

Future of what the cluster shows of the Comb right now:

  {
    phase   => 'Running',   # Running, Pending, Error, Stopped or NotDeployed
    healthy => 1,
    reason  => '...',       # when there is a problem: the first one's reason
    message => '...',       # every problem, joined with '; '
    pods    => [ { name, phase, ready, restarts, reason, message }, ... ]
  }

It looks for every rendered resource (by L</label_selector>) and at the Pods
of the Comb. C<NotDeployed>: none of the resources exists. C<Stopped>: the
workloads are scaled to zero or suspended, as L</stop> leaves them.
C<Running>: every resource exists, every Pod that should run has all its
containers ready, the replicated workloads have their ready replicas and the
Jobs completed. A Comb without workloads is running once its resources
exist. Waiting and terminated container reasons, restart counts and
C<PodScheduled=False> make up the reasons and messages; a reason that does not
pass by waiting (C<CrashLoopBackOff>, C<ImagePullBackOff>, a failed Job, a
failed Pod of its own) makes the phase C<Error>. Completed Pods never count
against the Comb; a failed Pod that belongs to a controller is left to it.

=cut

sub healthy {
  my ( $self ) = @_;
  return $self->status->then( sub { Future->done( $_[0]{healthy} ) } );
}

=method healthy

Future of a boolean: whether L</status> is C<Running>.

=cut

sub logs {
  my ( $self, %args ) = @_;
  my $lines = $args{lines} // 100;
  return Future->call( sub {
    $self->_pods->then( sub {
      my @streams = map { $self->_log_streams($_) } @_;
      return Future->needs_all( map { $self->_log_text( $_, $lines ) } @streams )->then( sub {
        my @texts = @_;
        my $headers = @streams > 1 || grep { $_->{previous} } @streams;
        return Future->done( join "\n", map {
          ( $headers ? '==> '.$streams[$_]{label}.' <=='."\n" : '' ).$texts[$_]
        } 0 .. $#streams );
      } );
    } );
  } );
}

=method logs

  print $comb->logs(lines => 50)->get;

Future of the last C<lines> (default 100) log lines of every container of the
Comb's Pods. With more than one container, each gets a C<==E<gt> pod/container
E<lt>==> header. A container in C<CrashLoopBackOff> shows its previous
instance, marked C<(previous)>. A container whose log cannot be read shows why
instead of failing the whole Future.

=cut

sub restart {
  my ( $self ) = @_;
  return Future->call( sub {
    my $patch = {
      spec => { template => { metadata => { annotations => {
        $self->restart_annotation => $self->_now
      } } } }
    };
    my $roll = sub { $self->k8s->patch( $_[0], patch => $patch, type => 'merge' ) };
    return $self->_each_workload(
      [ 'apps/v1/Deployment'  => $roll ],
      [ 'apps/v1/StatefulSet' => $roll ],
      [ 'apps/v1/DaemonSet'   => $roll ],
      [ 'batch/v1/Job'        => $self->_delete_job ]
    );
  } );
}

=method restart

Rolling restart: sets L</restart_annotation> to the current time (RFC 3339)
on the Pod template of every Deployment, StatefulSet and DaemonSet of the
Comb; deletes its Jobs. Future of the list of what it touched, as
C<Kind/name>.

=cut

sub stop {
  my ( $self ) = @_;
  return Future->call( sub {
    my $scale = sub { $self->k8s->patch( $_[0], patch => { spec => { replicas => 0 } }, type => 'merge' ) };
    return $self->_each_workload(
      [ 'apps/v1/Deployment'  => $scale ],
      [ 'apps/v1/StatefulSet' => $scale ],
      [ 'batch/v1/CronJob'    => sub {
        $self->k8s->patch( $_[0], patch => { spec => { suspend => JSON->true } }, type => 'merge' )
      } ],
      [ 'batch/v1/Job' => $self->_delete_job ]
    );
  } );
}

=method stop

Scales the Deployments and StatefulSets of the Comb to 0, suspends its
CronJobs and deletes its Jobs. Future of the list of what it touched, as
C<Kind/name>.

=cut

sub describe {
  my ( $self ) = @_;
  return Future->call( sub {
    my $recorded = $self->recorded_status;
    my %describe = (
      name       => $self->name,
      class      => ref $self,
      namespace  => $self->namespace,
      depends_on => [ $self->depends_on ],
      ( $self->is_stub ? ( stub_of => ref $self->stub_of ) : () ),
      ( $recorded ? ( recorded => $recorded->TO_JSON ) : () )
    );
    return $self->_resolve_endpoints->then( sub {
      $describe{endpoints} = [ map { $_->to_crd->TO_JSON } @_ ];
      return $self->status;
    } )->then( sub {
      $describe{status} = $_[0];
      return Future->done( \%describe );
    } );
  } );
}

=method describe

Future of a hashref with everything about the Comb, plain data:
C<name>, C<class>, C<namespace>, C<depends_on>, C<endpoints> (resolved, as
hashrefs), C<status> (see L</status>), C<recorded> (the L</recorded_status>,
when there is one) and C<stub_of> (class of the original, for a stub).

=cut

sub endpoint {
  my ( $self, $name ) = @_;
  return Future->call( sub {
    croak ref($self).'->endpoint needs a name' unless defined $name;
    return $self->_resolve_endpoints->then( sub {
      my ( $endpoint ) = grep { $_->name eq $name } @_;
      return Future->done($endpoint) if $endpoint;
      return Future->fail( ref($self).'->endpoint: '.$self->name.' has no endpoint '.$name
        .' (it has: '.( join( ', ', map { $_->name } @_ ) || 'none' ).')' );
    } );
  } );
}

=method endpoint

  my $ep = $comb->endpoint('client')->get;

Future of the L<Kubernetes::Comb::Endpoint> of that name, with its resolved
addresses. Fails for a name the Comb does not offer.

=cut

sub recorded_status {
  my ( $self ) = @_;
  return $self->has_crd ? $self->crd->status : $self->_memory_status;
}

=method recorded_status

The status the Comb last recorded, a L<Kubernetes::Comb::CRD::CombStatus>
or C<undef>: C<status> of L</crd>, without a custom resource the one kept in
memory. Unlike L</status> this reads nothing from the cluster.

=cut

####
#### Internals
####

# A contract method whose result may be a list or one Future of it, as a
# Future; whatever it dies with becomes the failure.
sub _hook {
  my ( $self, $method, @args ) = @_;
  return Future->call( sub {
    my @result = $self->$method(@args);
    return @result == 1 && blessed $result[0] && $result[0]->isa('Future')
      ? $result[0]
      : Future->done(@result);
  } );
}

sub _render {
  my ( $self ) = @_;
  return $self->_hook('manifests')->then( sub { Future->done( $self->_items(@_) ) } );
}

sub _items {
  my ( $self, @manifests ) = @_;
  return map { $self->_item($_) } @manifests;
}

# One manifest, ready to apply -- labelled, namespace set, a copy of what the
# class returned -- plus what the Comb needs to know about it.
sub _item {
  my ( $self, $manifest ) = @_;
  my $class = blessed $manifest;
  my $data = $class ? $manifest->TO_JSON : $manifest;
  croak ref($self).': a manifest is an IO::K8s object or a hashref, got '
    .( ref $manifest || 'a plain scalar' ) unless ref $data eq 'HASH';
  my $kind = $data->{kind};
  croak ref($self).': a manifest has no kind' unless defined $kind && length $kind;
  my $name = ref $data->{metadata} eq 'HASH' ? $data->{metadata}{name} : undef;
  croak ref($self).': manifest '.$kind.' has no metadata.name' unless defined $name && length $name;

  my $labels = $self->comb_labels;
  my $object = $self->_labeled( $data, [], $labels );
  $object->{apiVersion} //= $self->_api_version_of($kind);
  my ( $group ) = $object->{apiVersion} =~ m{\A(.+)/[^/]+\z};
  $group //= '';
  my $templates = $WORKLOAD_TEMPLATES{ $group.'/'.$kind };
  $object = $self->_labeled( $object, $_, $labels ) for @{ $templates // [] };
  my $namespace = $object->{metadata}{namespace};
  $object->{metadata}{namespace} = $namespace = $self->namespace
    if !( defined $namespace && length $namespace ) && $self->_namespaced( $class, $object );

  return {
    manifest   => $class ? $class->FROM_HASH($object) : $object,
    apiVersion => $object->{apiVersion},
    kind       => $kind,
    group      => $group,
    name       => $name,
    namespace  => $namespace,
    resource   => $class && $class ne 'IO::K8s::Unstructured'
      ? '+'.$class
      : $object->{apiVersion}.'/'.$kind,
    workload   => $templates ? 1 : 0
  };
}

# A copy of $node with $labels merged into the metadata at $path below it,
# copying only what it changes. A path that does not exist is left alone.
sub _labeled {
  my ( $self, $node, $path, $labels ) = @_;
  my %copy = %$node;
  if ( my ( $key, @rest ) = @$path ) {
    $copy{$key} = $self->_labeled( $copy{$key}, \@rest, $labels ) if ref $copy{$key} eq 'HASH';
    return \%copy;
  }
  my %meta = ref $copy{metadata} eq 'HASH' ? %{ $copy{metadata} } : ();
  $meta{labels} = { %{ $meta{labels} // {} }, %$labels };
  $copy{metadata} = \%meta;
  return \%copy;
}

sub _api_version_of {
  my ( $self, $kind ) = @_;
  my $io = $self->io_k8s;
  my $class = eval { my $c = $io->expand_class($kind); $io->load_class($c); $c };
  croak ref($self).': manifest '.$kind.' has no apiVersion, and '.$kind.' is no Kind IO::K8s knows'
    unless $class && $class->can('api_version');
  return $class->api_version;
}

# A Kind io_k8s does not know counts as namespaced: the parts of a Comb
# nearly always are, and the API server drops the namespace of a
# cluster-scoped object anyway.
sub _namespaced {
  my ( $self, $class, $object ) = @_;
  unless ( $class && $class ne 'IO::K8s::Unstructured' ) {
    $class = $self->io_k8s->expand_class( $object->{kind}, $object->{apiVersion} );
    return 1 unless defined $class;
    $self->io_k8s->load_class($class);
  }
  return $class->does('IO::K8s::Role::Namespaced') ? 1 : 0;
}

# Sequentially, so a Namespace or a CRD comes before what needs it.
sub _apply {
  my ( $self, @items ) = @_;
  my @applied;
  return ( fmap_void {
    my ( $item ) = @_;
    $self->k8s->ensure( $item->{manifest} )->then(
      sub { push @applied, $_[0]; Future->done },
      sub {
        Future->fail(
          'ensure '.$item->{kind}.' '.$item->{name}.': '.$_[0],
          deploy => { applied => [@applied], failed => $item->{manifest} }
        );
      }
    );
  } foreach => \@items, concurrent => 1 )->then( sub { Future->done(@applied) } );
}

# Puts the live object (or undef) of every item into $item->{live}: one list
# per resource and namespace, by label, so a missing object is an empty
# answer rather than an error to tell apart from others.
sub _fetch_live {
  my ( $self, @items ) = @_;
  my %groups;
  push @{ $groups{ $_->{resource} }{ $_->{namespace} // '' } }, $_ for @items;
  return Future->needs_all( map {
    my $resource = $_;
    map {
      my ( $namespace, $members ) = ( $_, $groups{$resource}{$_} );
      $self->k8s->list( $resource,
        ( length $namespace ? ( namespace => $namespace ) : () ),
        labelSelector => $self->label_selector
      )->then( sub {
        my %live = map { ( $_->metadata->name => $_ ) } @{ $_[0]->items // [] };
        $_->{live} = $live{ $_->{name} } for @$members;
        return Future->done;
      } );
    } sort keys %{ $groups{$resource} };
  } sort keys %groups );
}

sub _pods {
  my ( $self ) = @_;
  return $self->k8s->list( 'v1/Pod',
    namespace     => $self->namespace,
    labelSelector => $self->label_selector
  )->then( sub {
    return Future->done( sort { $a->metadata->name cmp $b->metadata->name } @{ $_[0]->items // [] } );
  } );
}

sub _status_of {
  my ( $self, $items, $pods ) = @_;
  my ( @pods, @problems );
  for my $pod (@$pods) {
    my ( $state, $problem ) = $self->_pod_state($pod);
    push @pods, $state;
    push @problems, $problem if $problem;
  }
  return $self->_verdict( Running => [], \@pods ) unless @$items;
  return $self->_verdict( NotDeployed => [ {
    severity => 'pending', reason => 'NotDeployed', message => 'not deployed'
  } ], \@pods ) unless grep { $_->{live} } @$items;
  return $self->_verdict( Stopped => [ {
    severity => 'pending', reason => 'Stopped', message => 'stopped'
  } ], \@pods ) if $self->_stopped($items);

  unshift @problems, map { +{
    severity => 'pending',
    reason   => 'ResourcesMissing',
    message  => $_->{kind}.' '.$_->{name}.' is missing'
  } } grep { !$_->{live} } @$items;
  push @problems, map { $self->_workload_problem($_) } grep { $_->{workload} && $_->{live} } @$items;

  my $phase = ( grep { $_->{severity} eq 'error' } @problems ) ? 'Error'
            : @problems                                        ? 'Pending'
            :                                                    'Running';
  return $self->_verdict( $phase, \@problems, \@pods );
}

sub _verdict {
  my ( $self, $phase, $problems, $pods ) = @_;
  my ( $first ) = ( ( grep { $_->{severity} eq 'error' } @$problems ), @$problems );
  return {
    phase   => $phase,
    healthy => $phase eq 'Running' ? JSON->true : JSON->false,
    ( $first ? (
      reason  => $first->{reason},
      message => join( '; ', map { $_->{message} } @$problems )
    ) : () ),
    pods    => $pods
  };
}

# What L</stop> leaves: every Deployment/StatefulSet at 0, every CronJob
# suspended, nothing else that keeps running (its Jobs it deletes).
sub _stopped {
  my ( $self, $items ) = @_;
  my $stoppable = 0;
  for my $item ( grep { $_->{workload} } @$items ) {
    my $key = $item->{group}.'/'.$item->{kind};
    next if $key eq 'batch/Job';
    return 0 unless $key eq 'apps/Deployment' || $key eq 'apps/StatefulSet' || $key eq 'batch/CronJob';
    next unless $item->{live};
    my $spec = $item->{live}->TO_JSON->{spec} // {};
    return 0 if $key eq 'batch/CronJob' ? !$spec->{suspend} : ( $spec->{replicas} // 1 ) != 0;
    $stoppable++;
  }
  return $stoppable ? 1 : 0;
}

sub _workload_problem {
  my ( $self, $item ) = @_;
  my $live   = $item->{live}->TO_JSON;
  my $spec   = $live->{spec}   // {};
  my $status = $live->{status} // {};
  my $what   = $item->{kind}.' '.$item->{name};
  my $key    = $item->{group}.'/'.$item->{kind};

  if ( $key eq 'batch/Job' ) {
    my %true = map { ( $_->{type} => $_ ) }
      grep { ( $_->{status} // '' ) eq 'True' } @{ $status->{conditions} // [] };
    if ( my $failed = $true{Failed} ) {
      return {
        severity => 'error',
        reason   => $failed->{reason} // 'JobFailed',
        message  => $what.' failed'.( $failed->{message} ? ': '.$failed->{message} : '' )
      };
    }
    return if $true{Complete} || ( $status->{succeeded} // 0 ) >= ( $spec->{completions} // 1 );
    return { severity => 'pending', reason => 'JobNotComplete', message => $what.' has not completed' };
  }

  my ( $ready, $desired );
  if ( $key eq 'apps/DaemonSet' ) {
    ( $ready, $desired ) = ( $status->{numberReady} // 0, $status->{desiredNumberScheduled} // 0 );
  }
  elsif ( $REPLICATED{$key} ) {
    ( $ready, $desired ) = ( $status->{readyReplicas} // 0, $spec->{replicas} // 1 );
  }
  else {
    return;   # a bare Pod speaks for itself, a CronJob has nothing to wait for
  }
  return if $ready >= $desired;
  return {
    severity => 'pending',
    reason   => 'ReplicasNotReady',
    message  => $what.': '.$ready.' of '.$desired.' ready'
  };
}

# The public view of a Pod, and the problem it is for the Comb, if any.
sub _pod_state {
  my ( $self, $pod ) = @_;
  my $data       = $pod->TO_JSON;
  my $status     = $data->{status} // {};
  my $phase      = $status->{phase} // 'Unknown';
  my @containers = @{ $status->{containerStatuses} // [] };
  my @all        = ( @{ $status->{initContainerStatuses} // [] }, @containers );
  my $restarts   = 0;
  $restarts += $_->{restartCount} // 0 for @all;
  my $ready = $phase eq 'Running' && @containers && !grep { !$_->{ready} } @containers;

  my %state = (
    name     => $data->{metadata}{name},
    phase    => $phase,
    ready    => $ready ? JSON->true : JSON->false,
    restarts => $restarts
  );
  return \%state if $phase eq 'Succeeded' || $ready;

  my ( $severity, $reason, $message );
  my ( $container ) = grep {
    $_->{state}{waiting} || ( $_->{state}{terminated} && ( $_->{state}{terminated}{exitCode} // 0 ) != 0 )
  } @all;
  my ( $unscheduled ) = grep {
    $_->{type} eq 'PodScheduled' && ( $_->{status} // '' ) eq 'False'
  } @{ $status->{conditions} // [] };

  if ( $phase eq 'Failed' ) {
    my $terminated = $container ? $container->{state}{terminated} : undef;
    $reason   = $status->{reason} // ( $terminated ? $terminated->{reason} : undef ) // 'Failed';
    $message  = $status->{message} // ( $terminated ? $self->_exit_message($terminated) : undef );
    $severity = @{ $data->{metadata}{ownerReferences} // [] } ? undef : 'error';
  }
  elsif ($unscheduled) {
    ( $severity, $reason, $message ) = ( 'pending', $unscheduled->{reason} // 'Unschedulable', $unscheduled->{message} );
  }
  elsif ( $container && ( my $waiting = $container->{state}{waiting} ) ) {
    $reason   = $waiting->{reason} // 'Waiting';
    $message  = $waiting->{message};
    $severity = $FAILURE_REASONS{$reason} ? 'error' : 'pending';
  }
  elsif ($container) {
    my $terminated = $container->{state}{terminated};
    ( $severity, $reason, $message ) = ( 'error', $terminated->{reason} // 'Error', $self->_exit_message($terminated) );
  }
  elsif ( $phase eq 'Unknown' ) {
    ( $severity, $reason, $message ) = ( 'error', $status->{reason} // 'Unknown', $status->{message} );
  }
  else {
    ( $severity, $reason ) = ( 'pending', $phase eq 'Pending' ? 'Pending' : 'ContainersNotReady' );
  }

  $state{reason}  = $reason;
  $state{message} = $message if defined $message;
  return \%state unless $severity;
  return ( \%state, {
    severity => $severity,
    reason   => $reason,
    message  => 'Pod '.$state{name}.': '.$reason
      .( defined $message && length $message ? ': '.$message : '' )
      .( $restarts ? ' ('.$restarts.' restarts)' : '' )
  } );
}

sub _exit_message {
  my ( $self, $terminated ) = @_;
  return 'exit code '.( $terminated->{exitCode} // '?' )
    .( $terminated->{message} ? ': '.$terminated->{message} : '' );
}

sub _log_streams {
  my ( $self, $pod ) = @_;
  my $data = $pod->TO_JSON;
  my $name = $data->{metadata}{name};
  my %status = map { ( $_->{name} => $_ ) } @{ $data->{status}{containerStatuses} // [] };
  my @containers = map { $_->{name} } @{ $data->{spec}{containers} // [] };
  return map {
    my $waiting  = $status{$_} && $status{$_}{state} ? $status{$_}{state}{waiting} : undef;
    my $previous = $waiting && ( $waiting->{reason} // '' ) eq 'CrashLoopBackOff' ? 1 : 0;
    +{
      pod       => $name,
      container => $_,
      previous  => $previous,
      label     => $name.( @containers > 1 ? '/'.$_ : '' ).( $previous ? ' (previous)' : '' )
    };
  } @containers;
}

sub _log_text {
  my ( $self, $stream, $lines ) = @_;
  return $self->k8s->log( 'v1/Pod', $stream->{pod},
    namespace => $self->namespace,
    container => $stream->{container},
    ( $stream->{previous} ? ( previous => 1 ) : () ),
    tailLines => $lines
  )->then(
    sub {
      my $text = $_[0] // '';
      $text .= "\n" if length $text && $text !~ /\n\z/;
      return Future->done($text);
    },
    sub { Future->done( '(no log: '.( $_[0] =~ s/\s+\z//r ).")\n" ) }
  );
}

# Lists each resource of the Comb by label, runs the action on every object
# found; Future of the list of what it touched, as Kind/name.
sub _each_workload {
  my ( $self, @actions ) = @_;
  return Future->needs_all( map {
    my ( $resource, $action ) = @$_;
    $self->k8s->list( $resource,
      namespace     => $self->namespace,
      labelSelector => $self->label_selector
    )->then( sub {
      my @objects = sort { $a->metadata->name cmp $b->metadata->name } @{ $_[0]->items // [] };
      return Future->needs_all( map {
        my $object = $_;
        $action->($object)->then( sub { Future->done( $object->kind.'/'.$object->metadata->name ) } );
      } @objects );
    } );
  } @actions );
}

# TODO: Kubernetes::REST and Net::Async::Kubernetes cannot send a
# propagationPolicy with delete yet (tickets on the kubernetes-rest and
# p5-net-async-kubernetes boards), so the deleted Job's Pods stay behind.
# Pass propagationPolicy => 'Background' here once they can.
sub _delete_job {
  my ( $self ) = @_;
  return sub { $self->k8s->delete( $_[0] ) };
}

sub _resolve_endpoints {
  my ( $self ) = @_;
  return Future->call( sub {
    Future->done( map { $self->_local_endpoint($_) } $self->_declared_endpoints );
  } );
}

sub _local_endpoint {
  my ( $self, $declared ) = @_;
  return $self->endpoint_class->new(
    name    => $declared->{name},
    port    => $declared->{port},
    ( defined $declared->{protocol} ? ( protocol => $declared->{protocol} ) : () ),
    cluster => $declared->{cluster}
      // ( $declared->{service} // $self->name ).'.'.$self->namespace.'.svc:'.$declared->{port},
    ( defined $declared->{external} ? ( external => $declared->{external} ) : () )
  );
}

sub _declared_endpoints {
  my ( $self ) = @_;
  my ( @declared, %seen );
  for my $endpoint ( $self->endpoints ) {
    my %declared;
    if ( blessed $endpoint && $endpoint->isa('Kubernetes::Comb::Endpoint') ) {
      %declared = (
        name     => $endpoint->name,
        port     => $endpoint->port,
        protocol => $endpoint->protocol,
        ( $endpoint->has_cluster  ? ( cluster  => $endpoint->cluster )  : () ),
        ( $endpoint->has_external ? ( external => $endpoint->external ) : () )
      );
    }
    elsif ( ref $endpoint eq 'HASH' ) {
      %declared = %$endpoint;
      my @unknown = sort grep { !$ENDPOINT_KEYS{$_} } keys %declared;
      croak ref($self).'->endpoints: unknown key(s) '.join( ', ', @unknown )
        .' (known: '.join( ', ', sort keys %ENDPOINT_KEYS ).')' if @unknown;
    }
    else {
      croak ref($self).'->endpoints: an endpoint is a hashref or a Kubernetes::Comb::Endpoint, got '
        .( ref $endpoint || 'a plain scalar' );
    }
    croak ref($self).'->endpoints: an endpoint has no name'
      unless defined $declared{name} && length $declared{name};
    croak ref($self).'->endpoints: endpoint '.$declared{name}.' is declared twice'
      if $seen{ $declared{name} }++;
    push @declared, \%declared;
  }
  return @declared;
}

sub _endpoint_names {
  my ( $self ) = @_;
  return map { $_->{name} } $self->_declared_endpoints;
}

sub _now { strftime( '%Y-%m-%dT%H:%M:%SZ', gmtime ) }

=seealso

=over

=item * L<Kubernetes::Comb::CRD::Comb> -- the custom resource

=item * L<Kubernetes::Comb::Role::Client> -- the client surface

=item * L<Kubernetes::Comb::Endpoint>

=back

=cut

1;
