# RIGHTCLICK PROJECT PHOENIX -- reproducible R/FFmpeg concept film
# Evidence classification: scene 4 is based on independently inspected local archive;
# scenes 5-11 are architectural VISUALISATIONS, NOT actual cloud execution.
options(warn=1, stringsAsFactors=FALSE)
outdir <- "promo/project-phoenix-film/output"
dir.create(outdir, recursive=TRUE, showWarnings=FALSE)
work <- tempfile("rc_phoenix_")
dir.create(work, recursive=TRUE)
on.exit(unlink(work, recursive=TRUE), add=TRUE)
for (cmd in c("ffmpeg","ffprobe","espeak-ng")) {
  if (Sys.which(cmd) == "") stop(sprintf("Missing renderer prerequisite: %s", cmd))
}
W <- 1280
H <- 720
FPS <- 24
titles <- c(
 "THE IMPOSSIBLE MACHINE",
 "SEVEN OPERATIONS. ONE INTERFACE.",
 "THE ENVIRONMENT IS THE TOOLBOX.",
 "REAL PROOF. NOT JUST A CLAIM.",
 "A NEW COMPUTATIONAL WORLD.",
 "AN ENVIRONMENT INSIDE AN ENVIRONMENT.",
 "A MISSION THAT NEEDS MORE COMPUTE.",
 "NOW DESTROY A WORKER.",
 "NO BLIND RETRY.",
 "RECONCILE. REAUTHORISE. CONTINUE.",
 "A SIGNATURE IS NOT A SUCCESS.",
 "ITS TOOLS NEVER CHANGED."
)
subs <- c(
 "Project Phoenix / RIGHTCLICK",
 "A stable AI-facing surface; capabilities vary at runtime.",
 "Discover what software and services actually expose.",
 "RIGHTCLICK queried GitHub and independently inspected a local ZIP.",
 "Target architecture: authorised disposable Linux execution.",
 "Target architecture: bounded and attenuated child delegation.",
 "Visualising deterministic work spread across available nodes.",
 "The target failure-recovery demonstration starts here.",
 "Unknown is not success. Provider acceptance is not proof.",
 "A safe replacement requires observation and approval.",
 "An independent observer checks the intended external outcome.",
 "ITS WORLD DID.  /  rightclick on GitHub"
)
narration <- c(
 "Imagine an artificial intelligence that does not need to know every tool it might ever use. What happens when its environment changes? Welcome to Project Phoenix.",
 "RIGHTCLICK exposes just seven generic operations to the agent. It identifies itself, inspects context, discovers capabilities, explains them, executes actions, reports status, and lists providers.",
 "Instead of teaching every agent every application, RIGHTCLICK discovers supported capability contracts from the environment. Local software and external services become available through the same stable interface.",
 "Here is a result already observed. RIGHTCLICK discovered GitHub as an Open A P I provider, queried a real repository, and returned H T T P two hundred. It then downloaded an open source video repository to a Mac. An independent inspection measured the archive at over one hundred and forty million bytes.",
 "Now the next frontier. This section is a concept visualisation, not a recorded live cloud result. A parent RIGHTCLICK runtime receives permission to provision a disposable, tightly limited Linux environment.",
 "That environment enrols with its own identity. A constrained lease permits it to request a smaller child environment. Authority narrows at each boundary. No parent credential needs to move into the child.",
 "A deterministic fractal is the mission. Independent workers receive pieces of the computation. Each segment can be checked mathematically, creating a striking final image and a clear test of correct execution.",
 "Here comes the dramatic failure. A worker disappears while computing. Its claimed result is no longer sufficient. RIGHTCLICK must distinguish work that finished from work that may have produced an uncertain external effect.",
 "The rule is simple. Do not retry uncertain side effects blindly. Observe the real external state, preserve the execution identity, check the original postcondition, and mark unresolved consequences as unknown.",
 "Once permissions and evidence permit it, unfinished work can be placed on a replacement runtime. This is the proposed cross machine recovery path. It remains an engineering acceptance gate, not a demonstrated production capability.",
 "Cryptographic signatures can authenticate who reported an event. They do not prove that the intended change happened. RIGHTCLICK aims to pair those reports with independent observation and tamper evident evidence.",
 "One stable capability interface. A changing world of authorised computation. Outcomes that must be checked, not merely asserted. RIGHTCLICK. Its tools never changed. Its world did. Cloud recovery shown in this film remains a concept."
)
scene_floor <- c(15,17,16,22,17,20,19,19,19,20,19,19)
types <- c("VISION","REAL ARCHITECTURE","REAL ARCHITECTURE","OBSERVED LOCAL EVIDENCE",
           rep("CONCEPT -- CLOUD EXECUTION NOT YET VERIFIED", 8))
dark <- "#07101E"
cyan <- "#54E9F3"
purple <- "#BA8AFF"
white <- "#EFFBFF"
soft <- "#AFC6DE"
green <- "#6BF5B9"
red <- "#FF7382"
box <- "#11243A"
bg <- function() {
  for (yy in seq(0, H, by=12)) {
    t <- yy/H
    rect(0, yy, W, yy+13,
      col=rgb(.015+.005*t,.027+.014*t,.058+.035*t),
      border=NA)
  }
  for (xx in seq(0,W,by=80)) segments(xx,0,xx,H,col="#112139",lwd=.6)
  for (yy in seq(0,H,by=80)) segments(0,yy,W,yy,col="#112139",lwd=.6)
  set.seed(90)
  stars <- cbind(runif(115,20,W-20),runif(115,70,H-15))
  points(stars[,1],stars[,2],pch=16,cex=runif(115,.11,.42),
         col=sample(c("#284A65","#38577B","#56799C"),115,replace=TRUE))
}
circle <- function(x,y,r,col,border=NA,lwd=1){
  a<-seq(0,2*pi,length.out=100)
  polygon(x+cos(a)*r,y+sin(a)*r,col=col,border=border,lwd=lwd)
}
node <- function(x,y,name,status="READY",color=cyan,rad=32) {
  circle(x,y,rad+20,adjustcolor(color,alpha.f=.07))
  circle(x,y,rad+11,adjustcolor(color,alpha.f=.13))
  circle(x,y,rad,adjustcolor(color,alpha.f=.24),border=color,lwd=2.6)
  circle(x,y,7,color)
  text(x,y-rad-24,name,col=white,cex=1.2,font=2)
  text(x,y-rad-48,status,col=color,cex=.85,font=2)
}
panel <- function(x0,y0,x1,y1,heading,lines,accent=cyan) {
  rect(x0,y0,x1,y1,col="#0F2238",border=accent,lwd=1.5)
  text(x0+20,y1-33,heading,col=accent,adj=0,cex=1.15,font=2)
  for (k in seq_along(lines))
    text(x0+20,y1-69-(k-1)*32,lines[k],col=white,adj=0,cex=.94,family="mono")
}
spark <- function(x,y,tone=cyan) {
  set.seed(as.integer(x+y))
  a<-seq(0,2*pi,length.out=35)
  for(j in seq_along(a)){
    r<-runif(1,30,100)
    segments(x,y,x+r*cos(a[j]),y+r*sin(a[j]),
      col=adjustcolor(tone,alpha.f=.25),lwd=1.2)
  }
}
makeFractal <- function() {
  nx<-670;ny<-310
  xv<-seq(-2.15,.65,length.out=nx)
  yv<-seq(-1.28,1.28,length.out=ny)
  cc<-rep(xv,each=ny)+1i*rep(yv,times=nx)
  zz<-complex(length=length(cc))
  n<-integer(length(cc))
  active<-rep(TRUE,length(cc))
  for (k in seq_len(50)) {
    zz[active]<-zz[active]*zz[active]+cc[active]
    escape<-active & Mod(zz)>2
    n[escape]<-k
    active[escape]<-FALSE
    if (!any(active)) break
  }
  n[active]<-50
  pal<-colorRampPalette(c("#07101E","#123C63","#20CDE0","#8F78F4","#F9C2FE"))(51)
  as.raster(matrix(pal[pmin(n+1L,51L)],nrow=ny,ncol=nx))
}
fractal<-makeFractal()
draw <- function(i,path) {
  png(path,width=W,height=H,bg=dark,type="cairo",res=96)
  par(mar=c(0,0,0,0),xaxs="i",yaxs="i")
  plot.new(); plot.window(xlim=c(0,W),ylim=c(0,H),asp=1)
  bg()
  rect(0,677,W,720,col="#101E33",border=NA)
  text(65,699,"RIGHTCLICK  /  PROJECT PHOENIX",col=cyan,adj=0,cex=.96,font=2)
  text(1210,699,sprintf("SCENE %02d / 12",i),col=soft,adj=1,cex=.88,family="mono")
  fontsize<-if(nchar(titles[i])>35) 2.2 else if(nchar(titles[i])>29) 2.55 else 3
  text(65,610,titles[i],col=white,adj=0,cex=fontsize,font=2)
  text(66,559,subs[i],col=soft,adj=0,cex=1.22)
  if (i==1) {
    spark(670,310,purple)
    node(390,325,"AGENT","NO NEW TOOLS",cyan,43)
    node(950,325,"WORLD","CHANGING",purple,43)
    segments(458,325,877,325,col=purple,lwd=7)
    text(665,369,"CAPABILITY FABRIC",col=white,cex=1.35,font=2)
  } else if(i==2) {
    ops<-c("context_runtime","context_inspect","context_actions",
      "context_explain","context_run","context_run_status","context_providers")
    for (j in seq_along(ops)){
      xx<-if(j<=4) 95 else 665
      yy<-465-((j-1)%%4)*84
      rect(xx,yy-32,xx+505,yy+32,col=box,border=cyan,lwd=1)
      text(xx+26,yy,ops[j],col=white,adj=0,cex=1.15,family="mono",font=2)
    }
  } else if(i==3) {
    node(640,310,"RIGHTCLICK","SEVEN OPERATIONS",cyan,45)
    pp<-matrix(c(260,390,1020,390,260,200,1020,200),ncol=2,byrow=TRUE)
    lbl<-c("macOS Services","OpenAPI","GraphQL / gRPC","Other approved providers")
    for(j in 1:4){
      segments(640,310,pp[j,1],pp[j,2],col=purple,lwd=2.5)
      node(pp[j,1],pp[j,2],lbl[j],"DISCOVERED",purple,22)
    }
  } else if(i==4) {
    panel(72,265,617,490,"PROVIDER ACCEPTANCE",
      c("GitHub REST API","HTTP GET /repos/...","Provider returned HTTP 200"),cyan)
    panel(659,265,1204,490,"SEPARATE LOCAL OBSERVATION",
      c("Mac: MoneyPrinterTurbo-main.zip","ZIP present / extracted folder","140,917,256 bytes observed"),green)
    text(638,167,"SUCCESS REQUIRES OBSERVATION, NOT JUST HTTP 200",
      col=white,font=2,cex=1.48)
  } else if(i %in% c(5,6,7,8,9,10)) {
    if(i==7) {
      rasterImage(fractal,330,125,1030,470,interpolate=TRUE)
      rect(329,124,1031,471,border=cyan,lwd=2)
      text(680,88,"DETERMINISTIC FRACTAL / PROPOSED WORKLOAD",
        col=cyan,font=2,cex=1.09)
    } else if(i==9){
      panel(140,170,590,470,"SAFE RECONCILIATION",
        c("1 / Observe external state","2 / Check original intent",
          "3 / Block unsafe retry","4 / Keep UNKNOWN if unclear"),red)
      panel(680,170,1130,470,"POLICY BEFORE EFFECT",
        c("No inferred permission","No fabricated success",
          "No duplicate side effect","Independent postcondition"),cyan)
    } else {
      segments(390,327,645,327,col=purple,lwd=5)
      segments(645,327,910,327,col=purple,lwd=5)
      node(390,327,"PARENT","HOST POLICY",cyan,37)
      node(645,327,"CHILD A","BOUNDED LEASE",purple,36)
      if(i==8) {
        node(910,327,"CHILD B","OFFLINE",red,36)
        segments(858,379,962,275,col=red,lwd=8)
        segments(858,275,962,379,col=red,lwd=8)
        text(900,138,"EXECUTION INTERRUPTED",col=red,cex=1.45,font=2)
      } else if(i==10) {
        node(910,327,"REPLACEMENT","PENDING APPROVAL",green,36)
        text(900,138,"RECONCILE BEFORE RESCHEDULING",col=green,cex=1.2,font=2)
      } else {
        node(910,327,"CHILD B","RESTRICTED",green,36)
        text(650,131,"CONSTRAINED / ATTESTED IDENTITY / NO SECRET EXPORT",
          col=soft,cex=1.08)
      }
    }
  } else if(i==11){
    node(200,312,"CHILD","SIGNED REPORT",purple,30)
    node(640,312,"OBSERVER","INDEPENDENT",cyan,30)
    node(1090,312,"HOST","ADJUDICATE",green,30)
    segments(271,313,560,313,col=purple,lwd=5)
    segments(715,313,1015,313,col=green,lwd=5)
    text(645,151,"A SIGNED CLAIM ALONE DOES NOT PROVE AN EFFECT",col=white,cex=1.32,font=2)
  } else if(i==12){
    rasterImage(fractal,720,95,1192,465,interpolate=TRUE)
    circle(470,309,125,adjustcolor(cyan,alpha.f=.06),border=cyan,lwd=2.3)
    text(470,325,"7",col=white,cex=7,font=2)
    text(470,225,"STABLE OPERATIONS",col=cyan,cex=1.3,font=2)
    text(640,92,"github.com/rossbuckley1990-hash/rightclick",
      col=white,cex=1.2)
  }
  rect(0,0,W,58,col="#0D2032",border=NA)
  type_color<-if(i==4) green else if(i>=5 && i<=11) "#FFE6AA" else soft
  text(60,31,types[i],col=type_color,adj=0,cex=.94,font=2,family="mono")
  text(1215,31,"DISCOVER   /   AUTHORISE   /   EXECUTE   /   VERIFY",
      col=soft,adj=1,cex=.87)
  dev.off()
}
echo_file <- file.path(work,"concat.txt")
segments <- character(length(titles))
actual_durations <- numeric(length(titles))
for(i in seq_along(titles)){
  message(sprintf("PHOENIX scene %d/12",i))
  img<-file.path(work,sprintf("scene-%02d.png",i))
  wav<-file.path(work,sprintf("voice-%02d.wav",i))
  txt<-file.path(work,sprintf("narration-%02d.txt",i))
  segment<-file.path(work,sprintf("clip-%02d.mp4",i))
  draw(i,img)
  writeLines(narration[i],txt,useBytes=TRUE)
  r<-system2("espeak-ng",c("-v","en-us","-s","151",
    "-w",shQuote(wav),"-f",shQuote(txt)),stdout=FALSE,stderr=FALSE)
  if(r!=0 || !file.exists(wav)) stop(sprintf("TTS failed for scene %d",i))
  ffprobe_output<-system2("ffprobe",c("-v","error","-show_entries",
    "format=duration","-of","default=noprint_wrappers=1:nokey=1",
    shQuote(wav)),stdout=TRUE)
  wav_length<-suppressWarnings(as.numeric(ffprobe_output[1]))
  if(is.na(wav_length))stop(sprintf("ffprobe failed for scene %d",i))
  d<-max(scene_floor[i],ceiling(wav_length)+2)
  actual_durations[i]<-d
  vf<-"scale=1344:756,zoompan=z='min(zoom+0.00008,1.034)':d=1:x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':s=1280x720:fps=24,format=yuv420p"
  args<-c("-hide_banner","-loglevel","error","-y",
    "-loop","1","-framerate",as.character(FPS),"-i",shQuote(img),
    "-i",shQuote(wav),"-vf",shQuote(vf),
    "-af","apad","-t",as.character(d),
    "-c:v","libx264","-preset","veryfast","-crf","27",
    "-pix_fmt","yuv420p","-r",as.character(FPS),
    "-c:a","aac","-b:a","96k","-movflags","+faststart",shQuote(segment))
  rc<-system2("ffmpeg",args,stdout=FALSE,stderr=FALSE)
  if(rc!=0 || !file.exists(segment) || file.info(segment)$size<5000)
    stop(sprintf("FFmpeg failed to render scene %d",i))
  segments[i]<-segment
}
writeLines(paste0("file '",normalizePath(segments,mustWork=TRUE),"'"),echo_file)
video<-file.path(outdir,"RIGHTCLICK-PROJECT-PHOENIX.mp4")
cmd<-c("-hide_banner","-loglevel","error","-y",
  "-f","concat","-safe","0","-i",shQuote(echo_file),
  "-c","copy","-movflags","+faststart",shQuote(video))
rc<-system2("ffmpeg",cmd,stdout=FALSE,stderr=FALSE)
if(rc!=0 || !file.exists(video)) stop("Final MP4 concat failed")
if(file.info(video)$size < 100000) stop("Final video unexpectedly small")
writeLines(c(
  "RIGHTCLICK PROJECT PHOENIX / EVIDENCE BOUNDARY",
  "The film is a concept visualization with one documented local evidence sequence.",
  "Observed Oct 9 2026 via RIGHTCLICK v0.2.2: GitHub API returned HTTP 200;",
  "MoneyPrinterTurbo ZIP independently observed on Mac at 140917256 bytes.",
  "The nested cloud create/destroy/recovery sequences are designs, not recorded live outcomes.",
  "Computer-generated R/FFmpeg scene visuals and offline TTS are not real execution footage.",
  sprintf("Rendered duration from scenes: %d seconds",sum(actual_durations)),
  sprintf("Final size: %d bytes",file.info(video)$size),
  "For actual nested-cloud claims require two real independent hosts, TTL guard,",
  "full runtime/credential isolation, signed evidence, independent observation and teardown."
),file.path(outdir,"EVIDENCE-BOUNDARY.txt"))
message(sprintf("PHOENIX COMPLETE duration=%d size=%d",
  sum(actual_durations),file.info(video)$size))
