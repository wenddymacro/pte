*! pte_example - Load pte package example dataset
*! version 1.0.0  2026-05-31
program define pte_example
    version 14.0
    syntax [, clear]
    
    if "`clear'" == "" {
        if c(changed) == 1 {
            display as error "no; dataset in memory has changed since last saved"
            display as error "    specify {bf:pte_example, clear} to discard changes"
            exit 4
        }
    }
    
    findfile pte_example.dta
    use "`r(fn)'", `clear'
    
    display as text ""
    display as text "{hline 60}"
    display as text "  pte example dataset loaded"
    display as text "{hline 60}"
    display as text "  Panel:     firm x year"
    display as text "  Output:    lny (log output)"
    display as text "  Inputs:    lnl (labor), lnk (capital), lnm (materials)"
    display as text "  Treatment: D (binary treatment indicator)"
    display as text "  Groups:    industry (3 categories)"
    display as text "{hline 60}"
    display as text ""
    display as text "  Quick start:"
    display as text "    {cmd:xtset firm year}"
    display as text "    {cmd:pte lny, free(lnl) state(lnk) proxy(lnm) treatment(D)}"
    display as text ""
end
