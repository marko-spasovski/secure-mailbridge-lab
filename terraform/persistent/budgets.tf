# Task 1.2 PR 2 (decision 144): the two cost budgets, imported as built.
# Both count unblended cost without credits and refunds, so a promotional
# credit can't hide real spend. Thresholds are percentages of the limit.

# Made by the console's budget template when the account was set up; kept by
# Marko. The forecast alert warns before the money is spent.
import {
  to = aws_budgets_budget.default
  id = "${local.account_id}:My Monthly Cost Budget"
}

resource "aws_budgets_budget" "default" {
  name              = "My Monthly Cost Budget"
  budget_type       = "COST"
  limit_amount      = "10.0"
  limit_unit        = "USD"
  time_unit         = "MONTHLY"
  time_period_start = "2026-10-01_00:00"
  time_period_end   = "2087-06-15_00:00"
  metrics           = ["UnblendedCost"]
  billing_view_arn  = "arn:aws:billing::${local.account_id}:billingview/primary"

  filter_expression {
    not {
      dimensions {
        key    = "RECORD_TYPE"
        values = ["Credit", "Refund"]
      }
    }
  }

  dynamic "notification" {
    for_each = [
      { type = "ACTUAL", threshold = 50 },
      { type = "ACTUAL", threshold = 100 },
      { type = "FORECASTED", threshold = 70 },
    ]
    content {
      notification_type          = notification.value.type
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value.threshold
      threshold_type             = "PERCENTAGE"
      subscriber_email_addresses = var.budget_default_emails
    }
  }
}

# The lab's own budget (task 1.1b, ARCHITECTURE §12): $20 a month.
import {
  to = aws_budgets_budget.lab
  id = "${local.account_id}:mailbridge-lab-monthly"
}

resource "aws_budgets_budget" "lab" {
  name              = "mailbridge-lab-monthly"
  budget_type       = "COST"
  limit_amount      = "20.0"
  limit_unit        = "USD"
  time_unit         = "MONTHLY"
  time_period_start = "2026-10-01_00:00"
  time_period_end   = "2087-06-15_00:00"
  metrics           = ["UnblendedCost"]

  filter_expression {
    not {
      dimensions {
        key    = "RECORD_TYPE"
        values = ["Credit", "Refund"]
      }
    }
  }

  dynamic "notification" {
    for_each = [50, 80, 100]
    content {
      notification_type          = "ACTUAL"
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      subscriber_email_addresses = var.budget_lab_emails
    }
  }
}
