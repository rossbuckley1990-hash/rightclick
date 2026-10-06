sales <- read.csv("/tmp/RIGHTCLICK-SALES.csv", stringsAsFactors = FALSE)
sales$month <- factor(sales$month, levels = sales$month)
out <- "/tmp/RIGHTCLICK-SALES-linechart.png"
png(out, width = 900, height = 500, res = 120)
par(mar = c(4.5, 4.5, 3.5, 1.5), bg = "white")
plot(seq_along(sales$month), sales$sales, type = "b", pch = 16, lwd = 2.5,
     col = "#2563eb", xlab = "Month", ylab = "Sales",
     main = "Sales by month", xaxt = "n", ylim = range(sales$sales) * c(0.95, 1.05),
     panel.first = grid(col = "grey90", lty = 1))
axis(1, at = seq_along(sales$month), labels = as.character(sales$month))
dev.off()
cat("WROTE", out, "BYTES", file.info(out)$size, "\n")
