## BlockTracer — the pipeline, static site and Demo Data Generator.
##
## This umbrella currently exposes only the **decoupling seam** delivered by
## milestones M5b (Data Contract) and M5c (Demo Data Generator). The explorer
## front end (M5/M9), the browser replay (M0/M1), and the publisher (M8) are later
## milestones and are deliberately NOT built here — see `docs/data-contract.md`.

import blocktracer/contract/version
import blocktracer/contract/model
import blocktracer/contract/ids
import blocktracer/validator
import blocktracer/demo/generator

export version, model, ids, validator, generator
