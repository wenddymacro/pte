* dependency.do - Automatically install pte dependencies
* This file is executed by 'github install' after package installation

capture which endopolyprodest
if _rc {
    display as text "[pte] Installing dependency: endopolyprodest..."
    capture ssc install endopolyprodest
    if _rc {
        display as text "[pte] endopolyprodest not on SSC, trying prodest..."
        capture ssc install prodest
    }
}

capture which reghdfe
if _rc {
    display as text "[pte] Installing optional dependency: reghdfe..."
    capture ssc install reghdfe
}

display as text "[pte] Dependency check complete"
