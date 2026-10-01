package Kubernetes::Comb::CRD::CombResource;
# ABSTRACT: Identity of one Kubernetes object a Comb manages
our $VERSION = '0.002';

use IO::K8s::Resource;

=description

An entry of C<status.managedResources> of a L<Kubernetes::Comb::CRD::Comb>:
enough to address an object the Comb deployed. Pruning compares the objects a
Comb renders now against this list; whatever is recorded here and no longer
rendered is an orphan.

=cut

k8s apiVersion => Str, { required => 1 };

=attr apiVersion

Required. C<v1>, C<apps/v1>, ...

=cut

k8s kind => Str, { required => 1 };

=attr kind

Required. C<Deployment>, C<Service>, ...

=cut

k8s namespace => Str;

=attr namespace

Namespace of the object; absent for cluster-scoped objects.

=cut

k8s name => Str, { required => 1 };

=attr name

Required. Name of the object.

=seealso

=over

=item * L<Kubernetes::Comb::CRD::CombStatus>

=back

=cut

1;
