import { defineRailway, project, service } from "railway/iac";

// decisions: the decisions cell. Variables stay unmanaged (secrets live in Railway only).
// decisions-api sleeps when idle (Railway Serverless) and wakes on the next request;
// decisions-publisher is a cron sweep of the outbox that exits after each run.
export default defineRailway(() => {
  const api = service("decisions-api", {
    healthcheck: "/health",
    healthcheckTimeout: 60,
    deploy: { sleepApplication: true },
  });
  const publisher = service("decisions-publisher", {
    startCommand: "decisions-publish",
    deploy: { cronSchedule: "*/15 * * * *", restartPolicyType: "NEVER" },
  });

  return project("decisions", {
    variables: { managed: false },
    resources: [api, publisher],
  });
});
