# NLB module — Network Load Balancer for Kubernetes ingress traffic
#
# Why NLB instead of MetalLB:
#   MetalLB L2 mode cannot claim public IPs on AWS (they are cloud NAT, not on
#   any network interface). NLB is the correct solution for kubeadm on EC2:
#   - NLB is internet-facing with a stable DNS name
#   - TCP pass-through on ports 80/443 to worker NodePorts 30080/30443
#   - nginx-ingress handles TLS termination — NLB is pure TCP
#   - cert-manager HTTP-01 challenge works: LE hits port 80 → NLB → 30080 → nginx
#   - If a worker goes down, NLB health checks remove it from rotation

resource "aws_lb" "ingress" {
  name               = "${var.cluster_name}-nlb"
  load_balancer_type = "network"
  internal           = false
  subnets            = var.public_subnet_ids

  # Enable cross-zone load balancing — distributes traffic evenly across all workers
  # regardless of which AZ the NLB receives the request in
  enable_cross_zone_load_balancing = true

  tags = {
    Name        = "${var.cluster_name}-nlb"
    Environment = var.environment
  }
}

# ── HTTP target group (port 80 → NodePort 30080) ─────────────────────────────
resource "aws_lb_target_group" "http" {
  name        = "${var.cluster_name}-http"
  port        = 30080
  protocol    = "TCP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  health_check {
    enabled             = true
    protocol            = "TCP"
    port                = "30080"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
  }

  tags = {
    Name        = "${var.cluster_name}-http-tg"
    Environment = var.environment
  }
}

# ── HTTPS target group (port 443 → NodePort 30443) ───────────────────────────
resource "aws_lb_target_group" "https" {
  name        = "${var.cluster_name}-https"
  port        = 30443
  protocol    = "TCP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  health_check {
    enabled             = true
    protocol            = "TCP"
    port                = "30443"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
  }

  tags = {
    Name        = "${var.cluster_name}-https-tg"
    Environment = var.environment
  }
}

# ── Register all worker nodes with both target groups ────────────────────────
resource "aws_lb_target_group_attachment" "http" {
  count            = length(var.worker_instance_ids)
  target_group_arn = aws_lb_target_group.http.arn
  target_id        = var.worker_instance_ids[count.index]
  port             = 30080
}

resource "aws_lb_target_group_attachment" "https" {
  count            = length(var.worker_instance_ids)
  target_group_arn = aws_lb_target_group.https.arn
  target_id        = var.worker_instance_ids[count.index]
  port             = 30443
}

# ── Listeners ────────────────────────────────────────────────────────────────
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.ingress.arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.http.arn
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.ingress.arn
  port              = 443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.https.arn
  }
}
