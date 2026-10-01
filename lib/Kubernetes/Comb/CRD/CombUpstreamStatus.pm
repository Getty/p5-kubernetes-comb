package Kubernetes::Comb::CRD::CombUpstreamStatus;
# ABSTRACT: Upstream section in the status of a Comb custom resource
our $VERSION = '0.002';

use IO::K8s::Resource;

=description

C<status.upstream> of a L<Kubernetes::Comb::CRD::Comb>, present only while an
upstream is active: which upstream, whether it is reachable, its phase and the
chain of layers the service is borrowed through.

=cut

k8s class => Str;

=attr class

Fully qualified class of the upstream, e.g.
C<Kubernetes::Comb::Upstream::K8s>.

=cut

k8s context => Str;

=attr context

Kube context the upstream lives in, where that applies. A context name only,
never credentials.

=cut

k8s reachable => Bool;

=attr reachable

Whether the upstream answered with a usable address.

=cut

k8s phase => Str;

=attr phase

The phase the upstream reports for itself.

=cut

k8s via => [Str];

=attr via

ArrayRef of the layers the service is borrowed through, nearest first, e.g.
C<[ 'dev', 'prod' ]>.

=cut

k8s observedAt => Time;

=attr observedAt

RFC 3339 timestamp of the observation.

=seealso

=over

=item * L<Kubernetes::Comb::CRD::CombStatus>

=back

=cut

1;
