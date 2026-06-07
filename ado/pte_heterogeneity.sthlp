{smcl}
{* *! version 1.0.0  01jan2026}{...}
{* *! pte_heterogeneity.sthlp - Help file for heterogeneity analysis}{...}
{* *! Chen, Liao & Schurter (2026)}{...}

{vieweralsosee "[PTE] pte" "help pte"}{...}
{vieweralsosee "[PTE] pte_graph" "help pte_graph"}{...}
{vieweralsosee "[PTE] pte_diagnose" "help pte_diagnose"}{...}
{vieweralsosee "[PTE] pte_compare" "help pte_compare"}{...}
{vieweralsosee "[PTE] pte_simulate" "help pte_simulate"}{...}
{vieweralsosee "[PTE] pte postestimation" "help pte postestimation"}{...}
{viewerjumpto "Syntax" "pte_heterogeneity##syntax"}{...}
{viewerjumpto "Description" "pte_heterogeneity##description"}{...}
{viewerjumpto "Options" "pte_heterogeneity##options"}{...}
{viewerjumpto "Remarks" "pte_heterogeneity##remarks"}{...}
{viewerjumpto "Examples" "pte_heterogeneity##examples"}{...}
{viewerjumpto "Stored results" "pte_heterogeneity##results"}{...}
{viewerjumpto "Error Messages" "pte_heterogeneity##errors"}{...}
{viewerjumpto "References" "pte_heterogeneity##references"}{...}
{viewerjumpto "Bug Reporting" "pte_heterogeneity##bugreport"}{...}
{viewerjumpto "Also see" "pte_heterogeneity##alsosee"}{...}

{cmd:help pte_heterogeneity}{right:also see: {help pte:pte}}
{hline}

{marker title}{...}
{title:Title}

{p2colset 5 30 32 2}{...}
{p2col:{hi:pte_heterogeneity} {hline 2}}Heterogeneity analysis of productivity
treatment effects{p_end}
{p2colreset}{...}


{marker syntax}{...}
{title:Syntax}

{p 8 16 2}
{cmd:pte_heterogeneity} {cmd:,} {opt by(name)} [{opt test}
{opt nocontribution} {opt level(#)} {opt tolerance(#)}]
{p_end}

{synoptset 28 tabbed}{...}
{synopthdr:options}
{synoptline}
{syntab:Grouping}
{synopt:{opt by(name)}}group by a discrete variable such as industry; the name
must match an existing grouping variable exactly{p_end}

{syntab:Testing}
{synopt:{opt test}}perform heterogeneity tests (Q statistic, I-squared){p_end}

{syntab:Reporting}
{synopt:{opt l:evel(#)}}set confidence level; default is {cmd:level(95)}{p_end}
{synopt:{opt nocon:tribution}}suppress contribution rate calculation{p_end}

{syntab:Advanced}
{synopt:{opt tol:erance(#)}}threshold for near-zero ATT detection; default is
{cmd:tolerance(1e-6)}{p_end}
{synoptline}
{p2colreset}{...}

{p 4 6 2}
{cmd:pte_heterogeneity} is a postestimation command. You must first run
{helpb pte}.{p_end}


{marker description}{...}
{title:Description}

{pstd}
{cmd:pte_heterogeneity} analyzes heterogeneity in treatment effects across
discrete groups after {helpb pte}. The live command requires a grouping
variable through {opt by(name)} and optionally reports formal
heterogeneity tests via {opt test}.

{pstd}
The implemented workflow corresponds to group-specific ATT aggregation:
the command recomputes group-level ATT, inherits bootstrap standard errors
when available, and optionally reports contribution shares.

{pstd}
After grouped {helpb pte} bootstrap runs, the inherited group bootstrap draws
follow the canonical grouped ATT track: with default trimming active they come
from the trimmed grouped bootstrap family, while {opt notrimeps} switches the
inheritance source to the raw grouped bootstrap family.
That inheritance path also requires the estimation-time grouped route metadata
{cmd:e(by)} and {cmd:e(groups)}. If either metadata object is missing, or if
the public {opt by(name)} request disagrees with stored {cmd:e(by)},
{cmd:pte_heterogeneity} now exits with {cmd:rc=198} instead of remapping
grouped bootstrap columns positionally.
That grouped bootstrap path also requires the exact estimation-time group
mapping in {cmd:e(groups)}. If grouped bootstrap draws survive but
{cmd:e(groups)} is missing, {cmd:pte_heterogeneity} exits with {cmd:rc=198}
instead of guessing that the current-data group order still matches the stored
bootstrap columns.
Grouped bootstrap reentry also requires {cmd:e(groups)} to remain unique:
duplicate route tokens are rejected with {cmd:rc=198} because they would let
multiple retained Table 2 groups point to the same stored bootstrap column.

When grouped bootstrap draws are reposted through the pooled shell
{cmd:e(att_boot_bygroup)}, that shell must also stay synchronized with the
stored route metadata: it must carry exactly one column per token in
{cmd:e(groups)}, and its column names must preserve the canonical grouped
replay order ({cmd:g1 ... gG}, with legacy fixture alias
{cmd:group1 ... groupG} also accepted). Reordered, renamed, or extra pooled
grouped-bootstrap columns are rejected with {cmd:rc=198} rather than guessed
back into the Table 2 route by position.


{marker options}{...}
{title:Options}

{dlgtab:Grouping}

{phang}
{opt by(name)} specifies a discrete (categorical) variable for grouping.
The command computes ATT separately for each category and stores the
group-level result matrix in {cmd:e(att_by_group)}.

{pmore}
The public command requires an exact existing grouping variable name.
Abbreviation-style inputs such as {cmd:by(ind)} are rejected if the data
only contain a column like {cmd:industry_shadow}; the live command does
not silently redirect heterogeneity analysis to a shadow grouping variable.

{pmore}
When grouped bootstrap ATT draws are active, {cmd:pte_heterogeneity} consumes
them through the exact estimation-time group order stored in {cmd:e(groups)}.
This route metadata is preserved in the reposted {cmd:e()} result so
{helpb pte_graph}, {cmd:heterogeneity} can reenter on the same grouped bundle
without collapsing it to positional current-data order. That repost is a
pooled Table 2 bundle: it supports the default pooled
{cmd:pte_graph, heterogeneity} replay, but it does not preserve
period-specific grouped bootstrap draws for {cmd:nt(#)} graphs. To graph a
specific event time with grouped bootstrap SEs, rerun {helpb pte} so the live
{cmd:e(att_boot_g#)} / {cmd:e(att_trim_boot_g#)} matrices and exact
{cmd:e(attperiods)} support are still available.
The stored {cmd:e(groups)} route must remain one-to-one: if the same token
appears more than once, the live command fail-closes with {cmd:rc=198} instead
of inheriting duplicated bootstrap columns under different group labels.
The pooled repost shell {cmd:e(att_boot_bygroup)} must remain synchronized with
that route: one column per stored token, and canonical ordered replay labels
({cmd:g1 ... gG}, or the legacy fixture alias {cmd:group1 ... groupG}). The
live command rejects reordered, renamed, or extra pooled grouped-bootstrap
columns with {cmd:rc=198}.

{pmore}
For string-valued grouping variables, the reposted {cmd:e(groups)} payload keeps
the exact surviving group tokens, including embedded spaces, in live graph
reentry order. The grouped bootstrap bridge does not split those labels into
positional fragments.

{pmore}
Only groups with at least one valid treated treatment-effect observation on the
exact stored support in {cmd:e(attperiods)} (nonmissing {cmd:_pte_tt} and
exact canonical {cmd:_pte_treat==1}) are retained in the reported table. Groups
that
are present in the raw data but absent from the treated post-treatment ATT
sample are excluded from the live heterogeneity output.

{pmore}
This exclusion rule does {bf:not} permit missing subgroup labels on the exact
supported treated TT sample. If any observation on that certified support has
missing {cmd:by()}, {cmd:pte_heterogeneity} exits with {cmd:rc=198} instead of
shrinking the Table 2 total row or reposted {cmd:e(sample)} to the labeled
subset.

{pmore}
When this option is used, the command also reports:

{phang3}(a) Group-specific ATT: tau_g = (1/n_g) * sum(TT_i){p_end}
{phang3}(b) Bootstrap standard errors{p_end}
{phang3}(c) Contribution rates (unless {opt nocontribution} is specified){p_end}

{pmore}
Contribution rate formula used by the live command:

{p 12 12 2}
Contribution_g (%) = (n_g/N) * tau_g / |tau_total| * 100
{p_end}

{pmore}
The contribution rates sum to sign(tau_total) * 100%, that is, +100% when
tau_total > 0 and -100% when tau_total < 0.

{dlgtab:Testing}

{phang}
{opt test} requests statistical tests for heterogeneity across
groups. The command reports:

{phang2}
{it:Cochran's Q statistic}: Tests the null hypothesis of homogeneous treatment
effects across groups. Under H_0:
{p_end}

{p 12 12 2}
Q = sum_g w_g * (tau_g - tau_pooled)^2 ~ chi2(G-1)
{p_end}

{pmore2}
where w_g = 1/SE_g^2 is the inverse variance weight.

{phang2}
{it:I-squared heterogeneity index}: Quantifies the percentage of total
variability attributable to heterogeneity rather than sampling error:
{p_end}

{p 12 12 2}
I2 = max(0, (Q - (G-1))/Q * 100%)
{p_end}

{pmore}
Interpretation guidelines (Higgins & Thompson, 2002):

{p 12 12 2}
I2 < 25%: Low heterogeneity{break}
25% <= I2 < 50%: Moderate heterogeneity{break}
50% <= I2 < 75%: Substantial heterogeneity{break}
I2 >= 75%: Considerable heterogeneity
{p_end}

{dlgtab:Reporting}

{phang}
{opt level(#)} specifies the confidence level, as a percentage, for confidence
intervals. The default is {cmd:level(95)} or as set by {helpb set level}.

{phang}
{opt nocontribution} suppresses the computation and display of contribution
rates in the group summary table.

{dlgtab:Advanced}

{phang}
{opt tolerance(#)} specifies the threshold for near-zero total ATT detection.
It must be strictly positive.
The live command uses a two-tier rule: when |tau_total| < 1e-8, contribution
rates are set to missing; when 1e-8 < |tau_total| <= tolerance, they are
computed with an explicit warning. The default is {cmd:tolerance(1e-6)}.

{pmore}
This option addresses numerical instability in the contribution rate formula
when the overall treatment effect is close to zero:

{p 12 12 2}
Contribution_g = (n_g/N) * tau_g / |tau_total| * 100
{p_end}

{pmore}
When |tau_total| is approximately 0, the contribution rates become unstable or
undefined. The tolerance threshold of 1e-6 is chosen to match Stata's
numerical precision while ensuring meaningful results (note: the paper's
Table 2 shows tau_total = -0.001, which is well above this threshold).

{pmore}
In particular, the implementation reserves the hard missing-value fallback for
the machine-zero case |tau_total| < 1e-8 and otherwise computes the shares
inside the tolerance band while flagging them as unreliable.

{marker remarks}{...}
{title:Remarks}

{pstd}
The implemented estimator is a discrete-group postestimation layer. For each
group defined by {opt by(name)}, the command recomputes group-specific ATT
from the stored treatment-effect objects produced by {helpb pte}, then
attaches bootstrap standard errors when bootstrap draws are available.

{pstd}
Contribution rates measure each group's share of the pooled ATT. When the
overall ATT is numerically close to zero, contribution rates become unstable;
the {opt tolerance(#)} option controls when the command suppresses them.

{pstd}
With {opt test}, the command reports Cochran's Q statistic and the I-squared
index to summarize cross-group heterogeneity. These statistics are only as
informative as the underlying bootstrap standard errors, so users should prefer
running {helpb pte} with {cmd:bootstrap(#)} before invoking this command.

{pstd}
Consistent with Section 6.4.1 of the paper, the public heterogeneity command
reports industry-level pooled ATT only and does not expose a group-by-period
dynamic ATT interface.

{pstd}
When group-level standard errors are inherited from grouped bootstrap draws,
those draws remain indexed by the estimation-time grouping variable and the
exact token order stored in {cmd:e(groups)}. The public command therefore
requires {cmd:e(by)} + {cmd:e(groups)} to match the requested {opt by(name)}
route before attaching grouped bootstrap uncertainty to the live Table 2
output.


{marker examples}{...}
{title:Examples}

{pstd}
{it:Setup: Run pte main estimation first}

{phang2}{cmd:. pte_example, clear}{p_end}
{phang2}{stata "xtset firm year":. xtset firm year}{p_end}
{phang2}{cmd:. pte lny, free(lnl) state(lnk) proxy(lnm) treatment(D) attperiods(3) pfunc(translog) omegapoly(3) bootstrap(100) seed(12345)}{p_end}

{pstd}
{it:Example 1: ATT by industry (Table 2 style)}

{phang2}{cmd:. pte_heterogeneity, by(industry)}{p_end}

{pstd}
{it:Example 2: Industry analysis with heterogeneity test}

{phang2}{cmd:. pte_heterogeneity, by(industry) test}{p_end}

{pstd}
{it:Example 3: Suppress contribution rates}

{phang2}{cmd:. pte_heterogeneity, by(industry) nocontribution}{p_end}

{pstd}
{it:Example 4: Custom tolerance for near-zero ATT}

{phang2}{cmd:. pte_heterogeneity, by(industry) tolerance(1e-4)}{p_end}

{pstd}
{it:Example 5: Extract results for further analysis}

{phang2}{cmd:. pte_heterogeneity, by(industry) test}{p_end}
{phang2}{cmd:. matrix list e(att_by_group)}{p_end}
{phang2}{cmd:. di "Q statistic = " e(Q_stat) ", p-value = " e(Q_pvalue)}{p_end}
{phang2}{cmd:. di "I-squared = " e(I2) "%"}{p_end}


{marker results}{...}
{title:Stored results}

{pstd}
{cmd:pte_heterogeneity} stores the following in {cmd:e()}:

{synoptset 30 tabbed}{...}
{p2col 5 30 34 2: Scalars}{p_end}
{synopt:{cmd:e(n_groups)}}number of groups{p_end}
{synopt:{cmd:e(total_att)}}overall ATT across all groups{p_end}
{synopt:{cmd:e(total_se)}}standard error of overall ATT{p_end}
{synopt:{cmd:e(total_n)}}total number of treated observations on the exact
stored ATT support from {cmd:e(attperiods)} and exact {cmd:_pte_treat==1}{p_end}
{synopt:{cmd:e(Q_stat)}}Cochran's Q statistic (if {cmd:test}){p_end}
{synopt:{cmd:e(Q_pvalue)}}p-value for Q statistic (chi-squared test){p_end}
{synopt:{cmd:e(df)}}degrees of freedom for Q test (G-1){p_end}
{synopt:{cmd:e(I2)}}I-squared heterogeneity index (percentage){p_end}
{synopt:{cmd:e(level)}}confidence level{p_end}

{p2col 5 30 34 2: Macros}{p_end}
{synopt:{cmd:e(cmd)}}{cmd:pte_heterogeneity}{p_end}
{synopt:{cmd:e(cmdline)}}command as typed{p_end}
{synopt:{cmd:e(by)}}grouping variable used by grouped heterogeneity
reentry{p_end}
{synopt:{cmd:e(by_var)}}name of grouping variable{p_end}
{synopt:{cmd:e(groups)}}exact group-token order retained for grouped bootstrap
reentry{p_end}
{synopt:{cmd:e(group_labels)}}labels for each group (space-separated){p_end}
{synopt:{cmd:e(title)}}title of estimation{p_end}

{p2col 5 30 34 2: Matrices}{p_end}
{synopt:{cmd:e(attperiods)}}1 x K row vector of exact supported ATT/TT event
times preserved for pooled graph reentry{p_end}
{synopt:{cmd:e(att_by_group)}}(G+1) x 4 matrix with contribution, or (G+1) x 3
with {cmd:nocontribution}{p_end}
{synopt:{cmd:e(att_by_group_se)}}G x 1 vector of group-level standard
errors{p_end}
{synopt:{cmd:e(att_by_group_ci)}}G x 2 matrix: [CI_lower, CI_upper]{p_end}
{synopt:{cmd:e(contribution)}}G x 1 vector of contribution rates;
    omitted when {cmd:nocontribution} is specified{p_end}
{p2colreset}{...}

{pstd}
{it:Matrix e(att_by_group) structure:}

{p 8 8 2}
Row 1 to G: Results for each group{break}
Row G+1: Total (aggregated across all groups){break}
Column 1: ATT estimate{break}
Column 2: Bootstrap standard error{break}
Column 3: Contribution rate (%) or sample size under {cmd:nocontribution}{break}
Column 4: Sample size (observations whose event times are listed in
{cmd:e(attperiods)}) when contribution is reported
{p_end}

{pstd}
The reposted estimation sample {cmd:e(sample)} follows that same exact-support
law: only treated observations with nonmissing {cmd:_pte_tt}, nonmissing
{cmd:by()}, and event times listed in {cmd:e(attperiods)} remain in
{cmd:e(sample)}. Unsupported leftover {cmd:_pte_nt} rows are excluded rather
than silently surviving into pooled graph reentry.

{pstd}
For the Total row, the live command first reuses the overall ATT standard
error exposed by {cmd:pte} in the last column of {cmd:e(att_se)}
({cmd:ATT_avg}). If that live bundle is present but {cmd:ATT_avg} itself is
missing, {cmd:pte_heterogeneity} now exits with {cmd:rc=198} instead of
reconstructing a new Total-row SE from the pooled TT sample. The
{cmd:sd/sqrt(N)} fallback is reserved only for reduced helper contexts where
no live {cmd:e(att_se)} bundle is posted at all.


{marker errors}{...}
{title:Error Messages}

{pstd}
{cmd:pte_heterogeneity} may issue the following errors:

{synoptset 8 tabbed}{...}
{synopt:{err:301}}pte has not been run; use {helpb pte} first{p_end}
{synopt:{err:111}}required exact bridge missing or malformed (including
{cmd:_pte_treat}){p_end}
{synopt:{err:198}}invalid public option value, or grouped bootstrap route
metadata {cmd:e(by)} / {cmd:e(groups)} are missing or inconsistent with
{cmd:by()}{p_end}
{synopt:{err:498}}at least 2 groups required for heterogeneity analysis{p_end}
{synopt:{err:459}}Bootstrap samples not available; rerun {helpb pte} with
bootstrap() option{p_end}
{synopt:{err:2000}}no observations after excluding missing values in by(){p_end}
{p2colreset}{...}

{pstd}
{it:Warnings}

{pstd}
The command issues warnings (but continues execution) in the following
situations:

{phang2}
{it:High cardinality variable}: When the grouping variable has more than 50
unique values, a warning suggests switching to a coarser discrete grouping
variable instead.
{p_end}

{phang2}
{it:Near-zero total ATT}: When 1e-8 < |ATT_total| <= tolerance (default 1e-6),
contribution rates are still computed, but the command warns that they are
numerically unstable. When |ATT_total| < 1e-8, contribution rates are set to
missing.
{p_end}

{phang2}
{it:Empty group}: When a group has no observations on the exact stored support
from {cmd:e(attperiods)}, the group is
skipped with a warning.
{p_end}

{marker references}{...}
{title:References}

{phang}
Chen, X., Liao, Z., and Schurter, K. (2026).
Identifying Treatment Effects on Productivity.
{it:Working Paper}.

{phang}
Ackerberg, D. A., Caves, K., and Frazer, G. (2015).
Identification Properties of Recent Production Function Estimators.
{it:Econometrica}, 83(6), 2411-2451.

{phang}
Cochran, W. G. (1954).
The Combination of Estimates from Different Experiments.
{it:Biometrics}, 10(1), 101-129.

{phang}
Higgins, J. P. T. and Thompson, S. G. (2002).
Quantifying Heterogeneity in a Meta-Analysis.
{it:Statistics in Medicine}, 21(11), 1539-1558.


{marker bugreport}{...}
{title:Bug Reporting}

{pstd}
Please report bugs, suggestions, and feature requests to:

{phang2}1. Email:
{browse "mailto:author@university.edu":author@university.edu}{p_end}
{phang2}2. GitHub Issues: {browse "https://github.com/xxx/pte/issues"}{p_end}

{pstd}
When reporting bugs, please include:

{phang2}- Stata version (type {cmd:version} in Stata){p_end}
{phang2}- Operating system (Windows/macOS/Linux){p_end}
{phang2}- Complete error message (copy and paste){p_end}
{phang2}- Minimal reproducible example{p_end}
{phang2}- Output of {cmd:which pte_heterogeneity}{p_end}

{pstd}
For issues related to the underlying PTE methodology, please refer to the
paper: Chen, Liao & Schurter (2026) "Identifying Treatment Effects on
Productivity".
