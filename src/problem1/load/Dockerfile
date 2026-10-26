FROM grafana/k6:latest@sha256:e66db15b860113878fa74670e31f5e274830b7b6e42c8bff28b2f2d86a257603
COPY scenario.js /scripts/scenario.js
ENTRYPOINT ["k6", "run", "--quiet", "/scripts/scenario.js"]
