package Kubernetes::Comb::CRD::CombStatus;
# ABSTRACT: Status of the Comb custom resource
our $VERSION = '0.001';

use IO::K8s::Resource;

use Kubernetes::Comb::CRD::CombCondition;
use Kubernetes::Comb::CRD::CombEndpoint;
use Kubernetes::Comb::CRD::CombResource;
use Kubernetes::Comb::CRD::CombUpstreamStatus;

=description

The C<status> of a L<Kubernetes::Comb::CRD::Comb>, written by the Comb itself
through the status subresource.

=cut

k8s phase => Str, {
  description => 'Running, Pending, Blocked, NeedsConfig, Disabled, Error,'
    .' Stopped or NotDeployed'
};

=attr phase

One of C<Running>, C<Pending>, C<Blocked>, C<NeedsConfig>, C<Disabled>,
C<Error>, C<Stopped>, C<NotDeployed>. Not enforced as an enum, so a status
written by a newer version still inflates.

=cut

k8s conditions => ['+Kubernetes::Comb::CRD::CombCondition'];

=attr conditions

ArrayRef of L<Kubernetes::Comb::CRD::CombCondition>.

=cut

k8s managedResources => ['+Kubernetes::Comb::CRD::CombResource'];

=attr managedResources

ArrayRef of L<Kubernetes::Comb::CRD::CombResource>: every object the Comb
deployed, the base for pruning.

=cut

k8s endpoints => ['+Kubernetes::Comb::CRD::CombEndpoint'];

=attr endpoints

ArrayRef of L<Kubernetes::Comb::CRD::CombEndpoint>, already resolved.

=cut

k8s upstream => '+Kubernetes::Comb::CRD::CombUpstreamStatus';

=attr upstream

L<Kubernetes::Comb::CRD::CombUpstreamStatus>, only while an upstream is
active.

=cut

k8s observedGeneration => Int;

=attr observedGeneration

C<metadata.generation> of the spec this status describes.

=seealso

=over

=item * L<Kubernetes::Comb::CRD::Comb>

=back

=cut

1;
