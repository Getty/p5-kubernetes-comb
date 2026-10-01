package Kubernetes::Comb::CRD::CombCondition;
# ABSTRACT: One condition in the status of a Comb custom resource
our $VERSION = '0.002';

use IO::K8s::Resource;

=description

An entry of C<status.conditions> of a L<Kubernetes::Comb::CRD::Comb>, shaped
like the conditions of the built-in Kinds, so the condition helpers of
L<IO::K8s::Role::APIObject> (C<get_condition>, C<is_condition_true>, ...) work
on a Comb custom resource as well.

=cut

k8s type => Str, { required => 1 };

=attr type

Required. The condition type, e.g. C<Ready>.

=cut

k8s status => Str, { required => 1, enum => [qw( True False Unknown )] };

=attr status

Required. C<True>, C<False> or C<Unknown>.

=cut

k8s reason => Str;

=attr reason

Machine-readable CamelCase reason for the last transition.

=cut

k8s message => Str;

=attr message

Human-readable detail.

=cut

k8s lastTransitionTime => Time;

=attr lastTransitionTime

RFC 3339 timestamp of the last change of L</status>.

=seealso

=over

=item * L<Kubernetes::Comb::CRD::CombStatus>

=back

=cut

1;
