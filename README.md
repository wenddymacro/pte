# pte

**Productivity Treatment Effects for Stata**

[![Stata 14.0+](https://img.shields.io/badge/Stata-14.0%2B-blue.svg)](https://www.stata.com/)
[![License: AGPL-3.0](https://img.shields.io/badge/License-AGPL--3.0-blue.svg)](LICENSE)
[![Version: 1.0.0](https://img.shields.io/badge/Version-1.0.0-green.svg)]()

<p align="center">
  <img src="image/image.png" alt="The Shadow of Efficiency - Productivity Treatment Effects" width="100%">
</p>

## Overview

`pte` implements the **Productivity Treatment Effects** framework proposed by Chen, Liao & Schurter (2026, *RAND Journal of Economics*) for Stata. The package integrates semiparametric production function estimation with causal treatment effect analysis, providing a unified toolkit for applied researchers studying how interventions affect productive efficiency.

The core innovation is the **CLK correction**: in ACF-style production function estimation, transition-period observations (where treatment status changes) are excluded, two separate productivity evolution paths are estimated, and counterfactual productivity is simulated via Monte Carlo to compute unbiased Average Treatment Effects on the Treated (ATT).

`pte` supports Cobb-Douglas and Translog production functions, clustered bootstrap inference, treatment-dependent production function extensions, cohort and heterogeneity analyses, and publication-quality visualization — all within a single, integrated workflow.

## Statement of Need

### The Problem

Estimating how policies or interventions affect firm productivity is a central question in industrial organization and development economics. Standard approaches face two fundamental challenges:

1. **Endogenous productivity in production function estimation.** Firms observe their own productivity before choosing inputs, creating simultaneous equations bias. The proxy variable approach (Olley-Pakes, Levinsohn-Petrin, ACF) addresses this but ignores treatment dynamics.

2. **Treatment-induced bias in productivity evolution.** When treatment changes a firm's productivity process, the standard Markov assumption is violated during the transition. Two-Way Fixed Effects (TWFE) regressions on recovered productivity confound the treatment effect with biased productivity estimates from the transition period.

### The CLK Solution

The Chen-Liao-Schurter framework solves both problems simultaneously:

- **Exclude transition-period observations** from the GMM moment conditions, so production function parameters are estimated without contamination from treatment switching.
- **Estimate separate evolution paths** for treated (h̄₁) and control (h̄₀) firms, allowing treatment to shift the entire productivity Markov process.
- **Simulate counterfactual paths** via Monte Carlo: "What would treated firms' productivity have been under h̄₀?" The difference is the ATT.

### Why Not TWFE?

A naive TWFE regression of recovered ω on treatment dummies produces biased estimates because (i) the production function parameters themselves are biased when transition observations are included, and (ii) a single pooled evolution law cannot represent heterogeneous treatment dynamics. `pte` eliminates both sources of bias.

## Key Features

- Semiparametric GMM production function estimation with CLK correction (Cobb-Douglas and Translog)
- Firm-level productivity recovery from estimated parameters
- ATT estimation through Monte Carlo counterfactual simulation (Proposition 4.3)
- Clustered bootstrap inference with stratified resampling
- Treatment-dependent production function extensions
- Cohort analysis, heterogeneity analysis (CATT), and method comparison
- Parallel computing support for grouped bootstrap acceleration
- Publication-quality visualization for treatment effects, diagnostics, and distributions
- Full `eclass` integration with `predict` postestimation support

## Core Method: The CLK Correction

The following illustrates how `pte` differs from standard approaches:

**Standard approach:**

All firms → Single production function → Pooled evolution law → **Transition bias** → Biased ATT

**`pte` approach (four stages):**

**Stage 1: Production Function Estimation (with CLK correction)**
- All firms → First-stage regression → φ (gross productivity)
- Exclude transitions (D_t ≠ D_{t-1}) from GMM moments
- GMM optimization → β (unbiased input elasticities)

**Stage 2: Productivity Recovery**
- ω = φ − f(k, l; β)
- Separate estimation of evolution paths:
  - h̄₀: ω_t = ρ₀ + ρ₁ω_{t-1} + ... (control path)
  - h̄₁: ω_t = ρ₀ + ρ₁ω_{t-1} + ... + γD + δDω (treated path)

**Stage 3: ATT via Monte Carlo Counterfactual**
- For each treated firm:
  - Simulate N paths under h̄₀ (control evolution + ε⁰ shocks)
  - ATT_i = ω_observed − E[ω_counterfactual]

**Stage 4: Bootstrap Inference**
- Stratified cluster resampling → Repeat Stages 1–3 → SE and CI

## Requirements

- **Stata 14.0** or later
- No additional dependencies for baseline estimation

**Optional workflow packages:**

| Package | Required For |
|---------|-------------|
| `reghdfe` | `pte_compare` (TWFE comparison) |
| `prodest` / `endopolyprodest` | Treatment-dependent production function workflows |
| `parallel` | Parallel bootstrap acceleration |

Use `pte_check_deps` to verify dependencies before advanced workflows.

## Installation

### From GitHub

```stata
net install pte, from("https://raw.githubusercontent.com/gorgeousfish/pte/main")
```

### From SSC (after public release)

```stata
ssc install pte
```

### Verify Installation

```stata
which pte
pte_version
help pte
```

## Quick Start

### Example 1: Basic Estimation (Cobb-Douglas)

The simplest use case estimates a Cobb-Douglas production function with the CLK correction and computes the ATT over a default 4-period horizon. This replicates the standard empirical exercise in Section 6 of the paper.

```stata
* Load bundled example dataset (installed with the package)
findfile pte_example.dta
use "`r(fn)'", clear
xtset firm year

* Estimate productivity treatment effects (Cobb-Douglas, point estimation)
pte lny, free(lnl) state(lnk) proxy(lnm) treatment(D) pfunc(cd)

* Display ATT estimates by event-time horizon
matrix list e(att)
```

The `e(att)` matrix reports ATT at each post-treatment period (nt0, nt1, ..., nt4) and the average across periods. Positive values indicate that treatment raised productivity.

### Example 2: Diagnostics and Visualization

Before trusting the ATT estimates, diagnostic checks verify the identifying assumptions. `pte_diagnose` tests parallel pre-trends and distributional assumptions, while `pte_graph` provides visual summaries.

```stata
* Run the main estimation first (required before diagnostics)
pte lny, free(lnl) state(lnk) proxy(lnm) treatment(D) pfunc(cd)

* Diagnostic tests for identifying assumptions
pte_diagnose, all

* Visualize ATT trajectory over event-time
pte_graph, att ci

* Visualize productivity evolution paths
pte_graph, evolution
```

### Example 3: Bootstrap Inference with Translog

This example demonstrates the Translog specification with bootstrap inference. The Translog production function allows non-constant returns to scale and input complementarities.

```stata
findfile pte_example.dta
use "`r(fn)'", clear
xtset firm year

* Translog with 200 bootstrap replications and time-trend control
gen trend = year
pte lny, free(lnl) state(lnk) proxy(lnm) treatment(D) ///
    pfunc(translog) bootstrap(200) control(trend) level(95)

* View confidence intervals
matrix list e(att_se)
matrix list e(att_ci_lower)
matrix list e(att_ci_upper)

* Publication graph with CIs
pte_graph, att ci saving(att_results.gph)
```

Bootstrap standard errors are computed via stratified cluster resampling at the firm level. With 200 replications, computation may take several minutes depending on sample size.

## Recommended Workflow

For a complete analysis, follow this four-step workflow:

| Step | Command | Purpose |
|------|---------|---------|
| 1. Setup | `pte_setup` | Validate panel structure, generate treatment-path indicators, diagnose data issues |
| 2. Estimate | `pte` | Production function estimation + productivity recovery + ATT computation |
| 3. Diagnose | `pte_diagnose` | Test identifying assumptions (parallel trends, conditional independence) |
| 4. Report | `pte_graph`, `pte_export` | Visualize results, export tables for publication |

**Extended workflow (optional):**

```stata
* Step 1: Data preparation and validation
pte_setup, treatment(D) report

* Step 2: Main estimation with bootstrap
pte lny, free(lnl) state(lnk) proxy(lnm) treatment(D) ///
    pfunc(translog) bootstrap(200)

* Step 3: Diagnostics
pte_diagnose, all

* Step 4: Visualization and export
pte_graph, att ci
pte_export results using "my_table.tex", format(latex) stars(0.01 0.05 0.10)

* Optional: Method comparison (requires reghdfe)
pte_compare, method(all) diagnose

* Optional: Heterogeneity analysis
pte_heterogeneity, by(industry) test
```

## Data Requirements

Your dataset must satisfy the following requirements before calling `pte`:

| Requirement | Description | Example |
|-------------|-------------|---------|
| Panel structure | Long format, one row per firm-period | Balanced or unbalanced panel |
| ID variable | Unique firm/unit identifier | `firm`, `plant_id` |
| Time variable | Numeric, `xtset`-compatible | `year`, `quarter` |
| Output (depvar) | Log output, continuous | `lny = log(revenue)` |
| Free input | Log freely-adjustable input, continuous | `lnl = log(labor)` |
| State variable | Log state/predetermined input, continuous | `lnk = log(capital)` |
| Proxy variable | Log proxy for unobserved productivity, continuous | `lnm = log(materials)` |
| Treatment | Binary (0/1), absorbing | `D = 1` after policy adoption |
| Missing values | No missing values in key variables | Use `drop if missing(...)` |
| Temporal depth | ≥2 pre-treatment periods recommended | For evolution estimation |

**Important notes:**
- All continuous variables should be in **logarithms** (the production function is log-linear).
- Treatment must be **absorbing** (once treated, always treated). Non-absorbing (reversible) treatment support is planned for v1.1.
- The panel must be declared with `xtset id time` before estimation.

## Command Reference

### Core Estimation

| Command | Description | When to Use |
|---------|-------------|-------------|
| `pte` | Main estimation: production function + ATT + bootstrap | Primary analysis command |
| `pte_setup` | Panel validation and treatment-path diagnostics | Before estimation, to verify data structure |
| `pte_diagnose` | Assumption diagnostics (parallel trends, KS tests) | After estimation, to validate identifying assumptions |

### Post-Estimation

| Command | Description | When to Use |
|---------|-------------|-------------|
| `pte_graph` | Results visualization (ATT, evolution, diagnostics) | After estimation, for visual inspection |
| `pte_compare` | Method comparison (CLK vs TWFE, endogenous) | To demonstrate CLK improvement over standard methods |
| `pte_heterogeneity` | Heterogeneity analysis (CATT by subgroup) | To examine treatment effect variation |
| `pte_export` | Export results to LaTeX/CSV/Excel | For publication tables |
| `pte_esttab_att` | Formatted ATT table output | For standardized ATT reporting |
| `pte_p` | Postestimation predictions (`predict` interface) | To recover ω, fitted values, residuals |

### Utility

| Command | Description | When to Use |
|---------|-------------|-------------|
| `pte_check_deps` | Verify optional package dependencies | Before using `pte_compare` or `treatdependent` |
| `pte_version` | Display version information | To check installed version |

## Stored Results

After estimation, `pte` stores results in `e()` accessible via `ereturn list`.

### Scalars

| Name | Description |
|------|-------------|
| `e(N)` | Number of observations used |
| `e(N_treated)` | Number of treated-firm observations |
| `e(N_control)` | Number of control-firm observations |
| `e(N_trans)` | Number of excluded transition observations |
| `e(N_g)` | Number of panel groups (firms) |
| `e(ATT_avg)` | Average ATT across all post-treatment periods |
| `e(ATT_avg_trim)` | Average ATT (trimmed ε⁰ distribution) |
| `e(att_0)` ... `e(att_k)` | ATT at each event-time horizon (k = 0, ..., attperiods) |
| `e(sigma_eps)` | Standard deviation of ε⁰ (innovation shock) |
| `e(sigma_eps_trim)` | σ(ε⁰) after Winsorization (1st–99th percentile) |
| `e(bootstrap)` | Number of bootstrap replications |
| `e(nsim)` | Number of Monte Carlo simulation paths |
| `e(omegapoly)` | Polynomial order for productivity evolution |
| `e(level)` | Confidence level |

### Matrices

| Name | Description |
|------|-------------|
| `e(att)` | 1×(K+2) ATT vector: [nt0, nt1, ..., ntK, avg] |
| `e(att_se)` | Bootstrap standard errors (same dimension as `att`) |
| `e(att_ci_lower)` | Lower confidence bound |
| `e(att_ci_upper)` | Upper confidence bound |
| `e(att_trim)` | ATT computed with trimmed ε⁰ |
| `e(b_by)` | Production function coefficients by group |
| `e(rho_by)` | Evolution parameters by group |
| `e(attperiods)` | Event-time horizon values |

### Macros

| Name | Description |
|------|-------------|
| `e(cmd)` | `"pte"` |
| `e(cmdline)` | Full command as typed |
| `e(depvar)` | Dependent variable name |
| `e(free)` | Free input variable |
| `e(state)` | State variable |
| `e(proxy)` | Proxy variable |
| `e(treatment)` | Treatment variable |
| `e(pfunc)` | Production function type (`cd` or `translog`) |
| `e(method)` | Estimation method (`acf`) |
| `e(correction)` | Correction applied (`clk`) |
| `e(predict)` | Prediction program (`pte_p`) |

For the complete list of stored results, see `help pte` or type `ereturn list` after estimation.

## Syntax Reference

The main estimation command:

```stata
pte depvar, free(varname) state(varname) proxy(varname) treatment(varname) [options]
```

**Required options:**

| Option | Description |
|--------|-------------|
| `free(varname)` | Free input variable (e.g., log labor) |
| `state(varname)` | State variable (e.g., log capital) |
| `proxy(varname)` | Proxy variable (e.g., log materials) |
| `treatment(varname)` | Binary treatment indicator (0/1) |

**Key estimation options:**

| Option | Default | Description |
|--------|---------|-------------|
| `pfunc(string)` | `translog` | Production function: `cd` or `translog` |
| `omegapoly(#)` | 3 | Productivity evolution polynomial order (1–4) |
| `attperiods(#)` | 4 | Maximum event-time horizon |
| `nsim(#)` | 100 | Number of Monte Carlo simulation paths |
| `bootstrap(#)` | 0 | Bootstrap replications (0 = point estimation only) |
| `by(varname)` | — | Group-by variable (e.g., industry) |
| `control(varlist)` | — | Controls for first-stage regression (e.g., a pre-generated `trend` variable) |
| `seed(#)` | 123456 | Random number seed for ATT simulation. Bootstrap uses sequential seeds (1, 2, ...); grouped estimation uses pathway-specific seeds. See `help pte` for details |
| `level(#)` | `c(level)` | Confidence level for bootstrap CIs |
| `treatdependent` | — | Enable treatment-dependent production function |
| `nolog` | — | Suppress progress output |

For complete syntax documentation, see `help pte` after installation.

## Roadmap

The following features are planned for future releases:

| Feature | Target | Description |
|---------|--------|-------------|
| Non-absorbing treatment | v1.1 | Support for reversible treatments where firms can exit treatment status |

## Citation

If you use `pte` in your research, please cite both the methodology paper and the software:

**Methodology paper:**
> Chen, Z., Liao, M., & Schurter, K. (2026). Identifying Treatment Effects on Productivity: Theory with an Application to Production Digitalization. *RAND Journal of Economics*.

**Software:**
> Cai, X. (2026). *pte: Stata module for Productivity Treatment Effects estimation* (Version 1.0.0) [Computer software]. https://github.com/gorgeousfish/pte

**BibTeX:**

```bibtex
@article{chen2026pte,
  title={Identifying Treatment Effects on Productivity: Theory with an
         Application to Production Digitalization},
  author={Chen, Zhiyuan and Liao, Moyu and Schurter, Karl},
  journal={RAND Journal of Economics},
  year={2026}
}

@software{pte2026stata,
  title={pte: Stata module for Productivity Treatment Effects estimation},
  author={Cai, Xuanyu},
  year={2026},
  version={1.0.0},
  url={https://github.com/gorgeousfish/pte}
}
```

## Authors

**Stata Implementation:**

- **Xuanyu Cai**, City University of Macau
  Email: [xuanyuCAI@outlook.com](mailto:xuanyuCAI@outlook.com)

**Methodology:**

- **Zhiyuan Chen**, University of Zurich
- **Moyu Liao**, City University of Macau
- **Karl Schurter**, University of Texas at Austin

## License

AGPL-3.0. See [LICENSE](LICENSE) for details.
