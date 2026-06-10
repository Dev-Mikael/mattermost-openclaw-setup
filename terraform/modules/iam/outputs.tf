output "control_plane_instance_profile" {
  value = aws_iam_instance_profile.control_plane.name
}

output "worker_instance_profile" {
  value = aws_iam_instance_profile.workers.name
}
