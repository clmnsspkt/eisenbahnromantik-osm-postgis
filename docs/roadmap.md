# Roadmap

This repository should grow in small, reviewable releases.

## V1: OSM/PostGIS Workflow

- publish the OSM flex import
- document isolated import schemas
- publish adapter view and target table SQL
- document verification queries and operational invariants

## V2: Minimal Demo Database

- add a small database bootstrap for required base tables
- add local PostGIS service to Compose
- document how preview checkpoints can be published into the demo checkpoint table
- next: add a documented small PBF workflow or generated fixture

## V3: GPX Processing

- add GPX parsing and normalization
- add checkpoint matching examples
- add tests around import fingerprints and geometry intersections

## V4: API Slice

- add FastAPI endpoints for checkpoint and admin-unit data
- document response shapes
- add focused API tests

## V5: Frontend Demo

- add a lightweight map view
- show checkpoint and admin-unit layers
- keep authentication and production deployment out until they are useful for public readers
