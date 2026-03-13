# Output values exposed to other modules
# Other modules can reference these ARNs

output "github_actions_role_arn" {
  description = "Role ARN for GitHub Actions to assume"
  value       = aws_iam_role.github_actions.arn
}

output "ecs_task_execution_role_arn" {
  description = "Role ARN for ECS task execution"
  value       = aws_iam_role.ecs_task_execution.arn
}

output "ecs_task_role_arn" {
  description = "Role ARN for ECS tasks (app permissions)"
  value       = aws_iam_role.ecs_task.arn
}