{smcl}
{* *! version 1.0.0  21Feb2026}{...}
{* *! Export estimation results for Productivity Treatment Effects}{...}
{* *! Chen, Liao & Schurter (2026)}{...}

{vieweralsosee "[PTE] pte" "help pte"}{...}
{vieweralsosee "[PTE] pte_graph" "help pte_graph"}{...}
{viewerjumpto "Syntax" "pte_export##syntax"}{...}
{viewerjumpto "Description" "pte_export##description"}{...}
{viewerjumpto "Options" "pte_export##options"}{...}
{viewerjumpto "Remarks" "pte_export##remarks"}{...}
{viewerjumpto "Examples" "pte_export##examples"}{...}
{viewerjumpto "Stored results" "pte_export##results"}{...}
{cmd:help pte_export}{right:also see: {help pte:pte}}
{hline}

{marker title}{...}
{title:Title}

{p2colset 5 22 24 2}{...}
{p2col:{hi:pte_export} {hline 2} Export pte estimation results to LaTeX, Excel, or CSV}{p_end}
{p2colreset}{...}


{marker syntax}{...}
{title:Syntax}

{p 8 16 2}{cmd:pte_export} {cmd:results} {cmd:using} {it:filename}
[{cmd:,} {it:options}]

{synoptset 28 tabbed}{...}
{synopthdr:Options}
{synoptline}
{syntab:Format}
{synopt:{opt for:mat(string)}}output format: {bf:latex} (default), {bf:xlsx}
(alias {bf:excel}), or {bf:csv}{p_end}

{syntab:Content}
{synopt:{opt se}}include standard errors when available (default){p_end}
{synopt:{opt nose}}suppress standard errors{p_end}
{synopt:{opt include(all)}}legacy compatibility alias for the full released
table; other values are rejected{p_end}
{synopt:{opt stars(numlist)}}three ascending significance thresholds strictly
inside (0,1); default is {cmd:0.01 0.05 0.10}; only with
{cmd:format(latex)}{p_end}
{synopt:{opt dec:imals(#)}}decimal places; default is {cmd:3}{p_end}

{syntab:LaTeX-specific}
{synopt:{opt title(string)}}table caption{p_end}
{synopt:{opt note(string)}}table footnote{p_end}

{syntab:General}
{synopt:{opt replace}}overwrite existing file{p_end}
{synoptline}
{p 4 6 2}{cmd:pte_export} requires current estimation results with
{cmd:e(att)} and {cmd:e(attperiods)} available (for example, from a prior
{cmd:pte} run that estimated ATT). Bootstrap output is optional; when present,
it adds standard
errors and p-values to all exports; significance stars plus caption/footnote
formatting are available only on the LaTeX path. Grouped ATT results from
{cmd:pte, by()} or {cmd:pte, industry()} are not accepted: those runs publish
group-specific ATT contracts ({cmd:e(att_by)} or {cmd:e(att_by_point)}), and
{cmd:pte_export} intentionally refuses to collapse them into one pooled
table.{p_end}


{marker description}{...}
{title:Description}

{pstd}
{cmd:pte_export} exports estimation results stored in {cmd:e()} to external
file formats suitable for inclusion in academic papers, presentations, or
further analysis.  Currently the only subcommand is {cmd:results}, which
exports the ATT, ATE{sup:count}, and Delta estimates along with any available
standard errors and p-values.  Significance stars are rendered only in the
LaTeX output.  The stored support matrix {cmd:e(attperiods)} must remain the
exact nonnegative event-time support for the dynamic ATT path; negative or
fractional support is rejected instead of being exported as if it were a
post-treatment horizon.

{pstd}
The current exporter supports only the pooled public ATT contract. If the
active {cmd:pte} result comes from the grouped {cmd:by()}/{cmd:industry()}
path, {cmd:pte_export} exits with an error instead of silently reusing pooled
{cmd:e(att)} and discarding the group-specific ATT surface. This grouped gate
is payload-based: if grouped ATT objects such as {cmd:e(att_by)},
{cmd:e(att_by_point)}, grouped pooled bootstrap summaries such as
{cmd:e(att_se_pool)} / {cmd:e(att_mean_pool)}, or per-group bootstrap payloads
such as {cmd:e(att_boot_g#)} / {cmd:e(att_se_g#)} survive in {cmd:e()},
{cmd:pte_export} still rejects the result even when grouped routing metadata
are incomplete.

{pstd}
Three output formats are supported:

{p 8 8 2}
{bf:LaTeX} ({cmd:format(latex)}): Generates a complete
{cmd:\begin{table}...\end{table}}
environment with {cmd:\hline} separators, significance stars, standard errors
in parentheses, and a footnote with star definitions.  The exporter wraps the
table body in {cmd:threeparttable}, so the output can be directly included in
a LaTeX document via {cmd:\input{}} when that package is loaded.

{p 8 8 2}
{bf:Excel} ({cmd:format(xlsx)}): Uses {cmd:putexcel} to write a formatted
spreadsheet with headers, numeric values, and metadata.  By default the
column layout is Period, ATT, ATT_SE, ATT_pval, and (if counterfactual)
ATE_count, ATE_count_SE, ATE_count_pval, Delta, Delta_SE, Delta_pval.
With {cmd:nose}, the standard-error columns are omitted.  Because the Excel
path remains numeric, explicit {cmd:title()}, {cmd:note()}, and {cmd:stars()}
options are rejected unless {cmd:format(latex)} is requested.

{p 8 8 2}
{bf:CSV} ({cmd:format(csv)}): Writes a comma-separated text file with the
same column structure as Excel, suitable for import into R, Python, or
other statistical software.  With {cmd:nose}, the standard-error columns
are omitted here as well.  Because the CSV path remains numeric, explicit
{cmd:title()}, {cmd:note()}, and {cmd:stars()} options are rejected unless
{cmd:format(latex)} is requested.


{marker options}{...}
{title:Options}

{dlgtab:Format}

{phang}
{opt format(string)} specifies the output format.  {bf:latex} (default)
produces a LaTeX table.  {bf:xlsx} (or {bf:excel}) produces an Excel file.
{bf:csv} produces a comma-separated values file.  When {cmd:format(excel)}
is used, the exporter normalizes the stored result to
{cmd:r(format)=xlsx}.

{dlgtab:Content}

{phang}
{opt se} includes bootstrap standard errors in the output (default behavior).

{phang}
{opt nose} suppresses standard errors from the output.  Point estimates and
LaTeX significance stars (if p-values are available) are still included.
In LaTeX output, this removes the SE columns and parenthetical SE entries
rather than leaving empty placeholders; numeric CSV/XLSX exports remain
star-free and keep their p-value columns.

{phang}
{opt include(all)} is a legacy compatibility alias for the full released
table.  The current released exporter does not implement partial content
selection, so any value other than {cmd:all} is rejected.

{phang}
{opt stars(numlist)} specifies three ascending significance thresholds for
star notation.  Each threshold must be strictly between 0 and 1.
Default is {cmd:0.01 0.05 0.10}, producing *** for p<0.01,
** for p<0.05, and * for p<0.10 in {cmd:format(latex)}.  Because the
CSV/XLSX paths stay numeric and export separate p-value columns instead of
star-marked text, explicit {cmd:stars()} is rejected unless
{cmd:format(latex)} is requested.

{phang}
{opt decimals(#)} specifies the number of decimal places for numeric output.
Default is {cmd:3}.  Must be between 0 and 8.

{dlgtab:LaTeX-specific}

{phang}
{opt title(string)} specifies the table caption in the LaTeX output.
Default is "Treatment Effects on Productivity".  It is rejected with
{cmd:format(csv)} or {cmd:format(xlsx)}.

{phang}
{opt note(string)} specifies a custom footnote for the LaTeX table.
If specified, the custom note is added as its own {cmd:\item} inside
{cmd:tablenotes}.  Automatic metadata notes for standard errors,
bootstrap iterations, and significance-star definitions are still
appended when those objects are present.  If {opt note()} is not
specified, only the automatic metadata notes are written.
It is rejected with {cmd:format(csv)} or {cmd:format(xlsx)}.

{dlgtab:General}

{phang}
{opt replace} permits overwriting an existing file.


{marker remarks}{...}
{title:Remarks}

{pstd}
{bf:Table structure}

{pstd}
The exported table contains one row per event-time support point in the
exact support published in {cmd:e(attperiods)}, plus a pooled row.  On the
canonical contiguous ATT path this happens to be {cmd:0, 1, ..., L}, but the
exporter does not reconstruct or relabel sparse support.  The stored support
must remain a strictly increasing integer event-time vector; if
{cmd:e(attperiods)} becomes fractional, duplicated, or otherwise malformed,
{cmd:pte_export} exits with {cmd:rc=198} instead of emitting mislabeled rows.
If the support matrix width no longer matches the dynamic ATT width implied by
{cmd:e(att)}, {cmd:pte_export} treats that as a shape-contract violation and
exits with {cmd:rc=503}.
Same-width matrices are also not enough: if a published dynamic payload keeps
the right width but permutes its dynamic column identities away from the exact
{cmd:e(attperiods)} order, {cmd:pte_export} exits with {cmd:rc=198} instead of
exporting values under the wrong event-time labels.
Each exported support row must also carry a realized ATT value and, when
the standardized counterfactual bundle is present, a realized
{cmd:ATE{sup:count}} value.  Missing placeholders on any stored support row
or on the pooled summary row now stop the export with {cmd:rc=198} instead
of emitting rows that claim support but contain holes.
When standard-error columns are requested, any published
{cmd:e(att_se)}, {cmd:e(ate_count_se)}, or {cmd:e(delta_se)} matrix must
also be complete on every exported support row and on the pooled summary.
Likewise, any published p-value matrix
({cmd:e(att_pval)}, {cmd:e(ate_count_pval)}, or {cmd:e(delta_pval)})
must be complete on the same exported support.  The exporter now fails
closed with {cmd:rc=198} instead of serializing supported rows with
inference holes.
Counterfactual columns are included only when the current
result object already publishes the standardized matrix {cmd:e(ate_count)}
alongside {cmd:e(att)}.  If {cmd:e(delta)} is absent, the exporter reconstructs
Delta as ATT - ATE{sup:count}.  The same normalization now applies when a
posted {cmd:e(delta)} matrix has holes on the exported support, because
Delta is a deterministic difference of the exported ATT and
{cmd:ATE{sup:count}} columns.  Raw Appendix D point workers that only store
names such as {cmd:e(ate_counterfactual)} must be standardized first before
they can be exported here.

{pstd}
{bf:Significance stars}

{pstd}
Stars are determined by the bootstrap p-values stored in {cmd:e(att_pval)},
{cmd:e(ate_count_pval)}, and {cmd:e(delta_pval)}.  The default thresholds
follow standard economics conventions: * p<0.1, ** p<0.05, *** p<0.01.

{pstd}
{bf:LaTeX compatibility}

{pstd}
The LaTeX output wraps {cmd:tabular} and any {cmd:tablenotes} footnotes inside
the {cmd:threeparttable} environment.  Documents that {cmd:\input{}} this
export must therefore load the {cmd:threeparttable} package.  When notes are
present (for example, default SE / bootstrap / significance-note output or any
explicit {cmd:note()}), they are emitted through {cmd:tablenotes}.  The table
body itself uses standard
{cmd:tabular} with {cmd:\hline\hline} borders.

{pstd}
Point-estimate results with {cmd:e(bootstrap)=0} do not emit bootstrap
metadata rows or footnotes; bootstrap metadata are exported only when the
stored bootstrap count is positive.


{marker examples}{...}
{title:Examples}

{pstd}
{bf:Setup}

{phang2}{cmd:. pte_example, clear}{p_end}
{phang2}{cmd:. xtset firm year}{p_end}

{phang2}.
{cmd:. * if you need ATE^count / Delta columns, first build a}
{cmd:.   standardized counterfactual result object that publishes}
{cmd:.   e(ate_count); if e(delta) is absent, pte_export}
{cmd:.   reconstructs Delta from ATT-ATE^count.}{p_end}

{pstd}
{bf:LaTeX export (default)}

{phang2}.
{stata "pte_export results using table1.tex, replace":pte_export results using table1.tex, replace}{p_end}

{phang2}.
{stata `"pte_export results using table1.tex, title("Digitalization Effects") replace"':pte_export results using table1.tex, title("Digitalization Effects") replace}{p_end}

{pstd}
{bf:LaTeX with custom stars and 4 decimal places}

{phang2}.
{stata "pte_export results using table1.tex, stars(0.01 0.05 0.10) decimals(4) replace":pte_export results using table1.tex, stars(0.01 0.05 0.10) decimals(4) replace}{p_end}

{pstd}
{bf:Excel export}

{phang2}.
{stata "pte_export results using results.xlsx, format(xlsx) replace":pte_export results using results.xlsx, format(xlsx) replace}{p_end}

{pstd}
{bf:CSV export}

{phang2}.
{stata "pte_export results using results.csv, format(csv) replace":pte_export results using results.csv, format(csv) replace}{p_end}

{pstd}
{bf:Suppress standard errors}

{phang2}.
{stata "pte_export results using table_compact.tex, nose replace":pte_export results using table_compact.tex, nose replace}{p_end}


{marker results}{...}
{title:Stored results}

{pstd}
{cmd:pte_export} stores the following in {cmd:r()}:

{synoptset 20 tabbed}{...}
{p2col 5 20 24 2: Scalars}{p_end}
{synopt:{cmd:r(n_periods)}}number of event-time periods exported{p_end}

{p2col 5 20 24 2: Macros}{p_end}
{synopt:{cmd:r(filename)}}output filename{p_end}
{synopt:{cmd:r(format)}}output format (latex, xlsx, or csv){p_end}
{synoptline}
