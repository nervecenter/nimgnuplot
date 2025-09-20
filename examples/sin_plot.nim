
import ../nimgnuplot

var g = initGnuplotScript(printScript = true)
g.cmd "set terminal png"
g.plot "sin(x)"
writeFile("sin_plot.png", g.execute())
