# HPA Validation — Amazon EKS

## Overview

This document records the Horizontal Pod Autoscaler (HPA) validation performed on the EKS environment. The goal was to confirm that Kubernetes could collect resource metrics, scale the application when CPU usage increased, and scale it back down after the workload was removed.

## Prerequisites

- Access to the EKS cluster with `kubectl` configured.
- Metrics Server installed and running.
- Application Deployments and HPAs already configured.
- A workload generator able to create CPU load against the application.

## 1. Verify Metrics Server

Metrics Server was deployed through Terraform using a Helm release.

Verify that the Metrics Server pod is running:

```bash
kubectl get pods -n kube-system | grep metrics-server
```

Verify that the metrics API is available:

```bash
kubectl get apiservice v1beta1.metrics.k8s.io
```

**Observed result:** `v1beta1.metrics.k8s.io` reported `AVAILABLE=True`.

Confirm that node and pod resource metrics can be retrieved:

```bash
kubectl top nodes
kubectl top pods -A
```

**Observed result:** Both commands returned resource metrics, confirming that the Metrics API was functioning.

## 2. Inspect HPAs

List the HPAs:

```bash
kubectl get hpa -A
```

The application HPAs (admin, auth, chat, and streaming) showed valid CPU metrics after Metrics Server became available; the CPU target was no longer reported as `<unknown>`.

## 3. Test Scale-Out

A load-generator pod was used to increase requests and CPU load against the admin service.

Observe the HPA:

```bash
kubectl get hpa -w
```

In another terminal, observe the Deployment:

```bash
kubectl get deployments -w
```

### Observed scale-out

| Measurement | Observed value |
|---|---|
| Admin replicas before load | 1 |
| CPU utilization during load | Approximately 302% |
| HPA CPU target | 70% |
| Admin replicas after scale-out | 3 |

**Result:** The admin HPA scaled from 1 to 3 replicas when CPU utilization rose above its configured target.

## 4. Test Scale-In

The load-generator pod was removed:

```bash
kubectl delete pod load-generator
```

Continue observing the HPA and Deployment:

```bash
kubectl get hpa -w
kubectl get deployments -w
```

### Observed scale-in

After the load generator was removed, CPU utilization returned below the target. The admin Deployment scaled down from 3 replicas to 2, and then to 1.

**Result:** Scale-in occurred automatically after the workload was removed and metrics returned below the target.

## 5. Final State

The final observed state was:

- Metrics Server pod healthy.
- Metrics API available.
- `kubectl top nodes` and `kubectl top pods` returned metrics.
- Admin, auth, chat, and streaming HPAs had valid CPU metrics.
- Application Deployments returned to 1 replica each.
- Admin Deployment was `1/1 READY`.
- Admin CPU utilization was low (approximately 8–9%) after the load test.

Check the current state with:

```bash
kubectl get hpa -A
kubectl get deployments -A
kubectl top pods -A
```

## Validation Summary

| Validation | Outcome |
|---|---|
| Metrics Server running | Passed |
| Metrics API available | Passed |
| Node/pod metrics query | Passed |
| HPA CPU metrics populated | Passed |
| Admin HPA scale-out (1 → 3) | Passed |
| Admin HPA scale-in (3 → 1) | Passed |
| Workload removed and baseline restored | Passed |

## Notes

- The CPU utilization value is the observed value from the test, not a guaranteed repeatable result; it can vary with workload and cluster conditions.
- HPA scale-in is not necessarily immediate. Kubernetes uses its scaling behavior and stabilization settings to avoid rapid replica changes.
- This validation demonstrates autoscaling behavior in the tested environment. It does not by itself establish production capacity or performance limits.
