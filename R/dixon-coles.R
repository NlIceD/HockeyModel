#Hosts dixon-coles specific functions. Many copied from my work from pbulsink.github.io
# see http://opisthokonta.net/?p=913
# see http://rstudio-pubs-static.s3.amazonaws.com/149923_584734fddffe40799cee564c938948d7.html

#' Update Dixon Coles parameters
#'
#' @param scores scores, if not then data(scores)
#'
#' @export
updateDC <- function(scores = HockeyModel::scores){
  scoresdc<-scores[scores$Date > as.Date("2008-08-01"),]
  message('Calculating new model parameters...')
  m <- getM(scores=scoresdc)
  message('Solving for low scoring games...')
  rho <- getRho(m = m, scores = scoresdc)
  suppressMessages(usethis::use_data(m, rho, overwrite = TRUE))
  return(list(m = m, rho=rho))
}

#' Produce a plot of each team's offence and defence scores
#'
#' @param m m from data(m)
#' @param teamlist Teams to plot.
#'
#' @return a ggplot object
#' @export
plotDC <- function(m = HockeyModel::m, teamlist = NULL){
  if(is.null(teamlist)){
    teamlist<-as.character(unique(m$data$Team))
  }
  team_params <- data.frame(Attack = as.numeric(m$coefficients[1:length(teamlist)]),
                            Defence = c(0, -m$coefficients[(length(teamlist)+1):(length(teamlist)*2-1)]),
                            Team = sort(teamlist))

  #Build and trim team colours for plot
  teamColoursList<-as.vector(HockeyModel::teamColours$Hex)
  names(teamColoursList)<-HockeyModel::teamColours$Team
  teamColoursList<-teamColoursList[names(teamColoursList) %in% teamlist]

  p<-ggplot2::ggplot(team_params,
                     ggplot2::aes_(x=quote(Attack),
                                   y=quote(Defence),
                                   color=quote(Team),
                                   label=quote(Team)
                                   )
                     ) +
    ggplot2::ggtitle("Current Team Attack & Defense Ratings", subtitle = paste0("As of ", Sys.Date(), ". Chart by @BulsinkB")) +
    ggplot2::xlab("Attack") +
    ggplot2::ylab("Defence") +
    ggplot2::geom_point() +
    ggplot2::scale_colour_manual(values = teamColoursList) +
    ggrepel::geom_text_repel(force=2, max.iter=5000) +
    ggplot2::theme_minimal() +
    ggplot2::theme(legend.position="none")
  return(p)
}

#' DC Predictions Today
#'
#' @param today Generate predictions for this date. Defaults to today
#' @param rho DC Rho
#' @param m DC m
#' @param schedule shcedule to use, if not the builtin
#' @param expected_mean the mean lambda & mu, used only for regression
#' @param season_percent the percent complete of the season, used for regression
#'
#' @return a data frame of HomeTeam, AwayTeam, HomeWin, AwayWin, Draw, or NULL if no games today
#' @export
todayDC <- function(today = Sys.Date(), rho=HockeyModel::rho, m = HockeyModel::m, schedule = HockeyModel::schedule, expected_mean = NULL, season_percent = NULL){
  games<-schedule[schedule$Date == today, ]
  if(nrow(games) == 0){
    return(NULL)
  }

  preds<-data.frame(HomeTeam=games$HomeTeam, AwayTeam=games$AwayTeam,
                    HomeWin=0, AwayWin = 0, Draw = 0,
                    stringsAsFactors = FALSE)
  for(i in 1:nrow(preds)){
    p<-DCPredict(preds$HomeTeam[[i]], preds$AwayTeam[[i]], m=m, rho=rho, expected_mean=expected_mean, season_percent=season_percent)
    preds$HomeWin[[i]]<-p[[1]]
    preds$AwayWin[[i]]<-p[[3]]
    preds$Draw[[i]]<-p[[2]]
  }

  return(preds)
}


#' Playoff Odds DC
#'
#' @param home Series Home Ice Advantage Team Name
#' @param away Away (Opponent) Team Name
#' @param rho HockeyModel::rho
#' @param m HockeyModel::m
#' @param home_wins Number of wins for home ice advantage team thus far in series
#' @param away_wins Number of wins for away team thus far in series
#'
#' @return home ice advantage team odds to win series
#' @export
playoffDC <- function(home, away, rho=HockeyModel::rho, m = HockeyModel::m, home_wins = 0, away_wins = 0){
  #Odds of home ice advantage team win at home
  homeodds<-DCPredict(home=home, away=away, m=m, rho=rho)
  homeodds<-normalizeOdds(c(homeodds[1], homeodds[3]))[1]
  #Odds of home ice advantage team win away
  awayodds<-DCPredict(home=away, away=home, m=m, rho=rho)
  awayodds<-normalizeOdds(c(awayodds[3], awayodds[1]))[1]

  homewin<-playoffSeriesOdds(homeodds, awayodds, home_wins, away_wins)
  return(homewin)
}


#' DC Simulate season with reevaluation every n days
#'
#' @param nsims number of simulations
#' @param scores hisotircal scores
#' @param schedule schedule this season
#' @param cores number of cores to process
#' @param ndays number of days of games to play before reevaluating m
#' @param regress Whether to regress toward mean
#' @param progress Whether to show a progress bar.
#'
#' @return data frame of Team point ranges, playoff odds, etc.
#' @export
dcRealSeasonPredict<-function(nsims=1e5, scores = HockeyModel::scores, schedule = HockeyModel::schedule, cores = parallel::detectCores()-1, ndays=7, regress=FALSE, progress = FALSE){

  schedule$Date<-as.Date(schedule$Date)
  schedule<-schedule[schedule$Date > max(scores$Date), ]
  dcscores<-scores[scores$Date > as.Date("2005-08-01"),]
  dcscores<-droplevels(dcscores)
  dcscores$Winner <- NULL
  dcscores$Loser <- NULL
  dcscores$League <- NULL
  dcscores$Tie <- NULL

  #Get a tie performance for each team.
  dcscores.ot<-dcscores[dcscores$OTStatus != '', ]
  dcscores.ot$minscore<-pmin(dcscores.ot$HomeGoals, dcscores.ot$AwayGoals)
  dcscores.ot$HomeGoals<-dcscores.ot$HomeGoals-dcscores.ot$minscore
  dcscores.ot$AwayGoals<-dcscores.ot$AwayGoals-dcscores.ot$minscore

  dcscores$OTStatus <- NULL
  dcscores.ot$minscore <- NULL

  #Generate m
  dc.m.ot <- getM(scores=dcscores.ot, currentDate = schedule$Date[[1]])
  dc.m.original <- getM(scores = dcscores, currentDate = schedule$Date[[1]])
  rho <- HockeyModel::rho

  if(regress){
    last_game_date<-as.Date(max(scores$Date))
    season_end_date <- as.Date(max(schedule$Date))
    season_start_date <- as.Date(min(c(scores[scores$Date > as.Date('2018-10-01'), 'Date'], schedule[schedule$Date > as.Date('2018-10-01'), 'Date'])))
    season_length <- as.integer(season_end_date) - as.integer(season_start_date)
    remaining_length <- as.integer(season_end_date) - as.integer(last_game_date)
    expected_mean<-2.835184
  }

  maxgoal<-10

  `%dopar%` <- foreach::`%dopar%`
  cl<-parallel::makeCluster(cores)
  doSNOW::registerDoSNOW(cl)
  if(progress){
    pb<-utils::txtProgressBar(max = nsims, style = 3)
    progress <- function(n) utils::setTxtProgressBar(pb, n)
    opts <- list(progress = progress)
  } else {
    opts <- list()
  }
  #all_results <- data.frame(Team = character(), GP = integer(), Points = integer(), W = integer(), L = integer(), OTL = integer(), SOL = integer(), SOW = integer(), Rank = integer(), ConfRank = integer(), DivRank = integer(), Playoffs = integer())

  all_results <- foreach::foreach(i=1:nsims, .combine='rbind', .options.snow = opts, .packages=c("HockeyModel")) %dopar%{ #, DCPredictErrorRecover = DCPredictErrorRecover) %dopar% {
  #for(i in 1:nsims){
    dc.m <- dc.m.original
    results<-schedule
    results$HomeGoals<-NA
    results$AwayGoals<-NA
    results$Result<-NA
    results<-dplyr::bind_rows(dcscores[dcscores$Date > as.Date("2018-10-01"),], results)

    lastdate<-as.Date(schedule$Date[[1]])

    for(g in which(is.na(results$Result))){
      if(results$Date[[g]] > (lastdate + ndays)){
        #New dc.m
        newscores<-rbind(dcscores, results[results$Date<results$Date[[g]], ])
        dc.m<-getM(scores = newscores, currentDate = results$Date[[g]])
        lastdate<-results$Date[[g]]
      }

      home<-results$HomeTeam[[g]]
      away<-results$AwayTeam[[g]]
      # Expected goals home
      lambda <- try(stats::predict(dc.m, data.frame(Home = 1, Team = home, Opponent = away), type = "response"), TRUE)

      # Expected goals away
      mu<-try(stats::predict(dc.m, data.frame(Home = 0, Team = away, Opponent = home), type = "response"), TRUE)

      #Fix something wrong with expected away or home goals
      if(!is.numeric(lambda)){
        message("unknown lambda")
        lambda<-DCPredictErrorRecover(team = home, opponent = away, homeiceadv = TRUE, m = dc.m)
      }
      if(!is.numeric(mu)){
        message("unknown mu")
        mu<-DCPredictErrorRecover(team = away, opponent = home, homeiceadv = FALSE, m = dc.m)
      }

      if(regress){
        #Adjust regress to mean
        season_percent <- (remaining_length - as.integer(season_end_date - as.Date(results$Date[[g]])))/season_length
        lambda <- lambda * (1-1/3 * season_percent) + expected_mean * (1/3 * season_percent)
        mu <- mu * (1-1/3 * season_percent) + expected_mean * (1/3 * season_percent)
      }

      #Another new goal prediction method by poisson & d/c handling of low scores:
      probability_matrix <- stats::dpois(0:maxgoal, lambda) %*% t(stats::dpois(0:maxgoal, mu))


      scaling_matrix <- matrix(tau(c(0, 1, 0, 1), c(0, 0, 1, 1), lambda, mu, rho), nrow = 2)
      probability_matrix[1:2, 1:2] <- probability_matrix[1:2, 1:2] * scaling_matrix

      goals<-data.frame(Goals = c(0:maxgoal), Home = 0, Away = 0)

      goals$Away<-colSums(probability_matrix)*1/sum(colSums(probability_matrix))
      goals$Home<-rowSums(probability_matrix)*1/sum(rowSums(probability_matrix))

      #Sum of densities (1 indexed... row 1 == 0 goals) for randomly getting a reasonable goal total

      hg<-cumsum(goals$Home)
      ag<-cumsum(goals$Away)

      #Use runif to get a goals total, then adjust for 0/1 off-index. max includes... ,1 for error prevention (e.g. no hg < runif(1))
      homegoals<-max(which(hg < stats::runif(1)), 1)-1
      awaygoals<-max(which(ag < stats::runif(1)), 1)-1

      #Deal with ties
      if(homegoals == awaygoals){
        p<-DCPredict(home = home, away = away, m=dc.m.ot, rho=0, maxgoal=1, scores=NULL)
        pHome<-normalizeOdds(c(p[[1]], 0, p[[3]]))[[1]]
        if(stats::runif(1) < pHome){
          homegoals <- homegoals + 1
          if(stats::runif(1) > p[[2]]){
            results$Result[[g]] <- 0.75
          } else {
            results$Result[[g]] <- 0.60
          }
        } else {
          awaygoals <- awaygoals + 1
          if(stats::runif(1) > p[[2]]){
            results$Result[[g]] <- 0.25
          } else {
            results$Result[[g]] <- 0.40
          }
        }
      } else {
        results$Result[[g]]<-ifelse(homegoals>awaygoals, 1, 0)
      }

      results$HomeGoals[[g]] <- homegoals
      results$AwayGoals[[g]] <- awaygoals
    }
    table<-buildStats(results)
  }

  if(progress){
    close(pb)
  }
  parallel::stopCluster(cl)
  gc(verbose = FALSE)

  summary_results<-all_results %>%
    dplyr::group_by(!!dplyr::sym('Team')) %>%
    dplyr::summarise(
      Playoffs = mean(!!dplyr::sym('Playoffs')),
      meanPoints = mean(!!dplyr::sym('Points'), na.rm = TRUE),
      maxPoints = max(!!dplyr::sym('Points'), na.rm = TRUE),
      minPoints = min(!!dplyr::sym('Points'), na.rm = TRUE),
      meanWins = mean(!!dplyr::sym('W'), na.rm = TRUE),
      maxWins = max(!!dplyr::sym('W'), na.rm = TRUE),
      Presidents = sum(!!dplyr::sym('Rank') == 1)/dplyr::n(),
      meanRank = mean(!!dplyr::sym('Rank'), na.rm = TRUE),
      bestRank = min(!!dplyr::sym('Rank'), na.rm = TRUE),
      meanConfRank = mean(!!dplyr::sym('ConfRank'), na.rm = TRUE),
      bestConfRank = min(!!dplyr::sym('ConfRank'), na.rm = TRUE),
      meanDivRank = mean(!!dplyr::sym('DivRank'), na.rm = TRUE),
      bestDivRank = min(!!dplyr::sym('DivRank'), na.rm = TRUE),
      sdPoints = stats::sd(!!dplyr::sym('Points'), na.rm = TRUE),
      sdWins = stats::sd(!!dplyr::sym('W'), na.rm = TRUE),
      sdRank = stats::sd(!!dplyr::sym('Rank'), na.rm = TRUE),
      sdConfRank = stats::sd(!!dplyr::sym('ConfRank'), na.rm = TRUE),
      sdDivRank = stats::sd(!!dplyr::sym('DivRank'), na.rm = TRUE)
    )


  return(list(summary_results = summary_results, raw_results = all_results))
}


#' DC remainder of season
#' @description Odds for each team to get to playoffs.
#'
#' @param nsims Number of simulations
#' @param scores the historical scores
#' @param schedule uplayed future games
#' @param odds whether to return odds table or simulate season
#' @param regress whether to apply a regression to the mean for team strength on future predictions
#' @param ... arguements to pass to dc predictor
#'
#' @return data frame of Team, playoff odds.
#' @export
remainderSeasonDC <- function(nsims=1e4, scores = HockeyModel::scores, schedule = HockeyModel::schedule, odds = FALSE, regress = TRUE, ...){

  odds_table<-data.frame(HomeTeam = character(), AwayTeam=character(),
                    HomeWin=numeric(), AwayWin=numeric(), Draw=numeric(),
                    stringsAsFactors = FALSE)

  last_game_date<-as.Date(max(scores$Date))
  schedule <- schedule[schedule$Date > last_game_date, ]

  if(regress){
    season_end_date <- as.Date(max(schedule$Date))
    season_start_date <- as.Date(min(c(scores[scores$Date > as.Date('2018-10-01'), 'Date'], schedule[schedule$Date > as.Date('2018-10-01'), 'Date'])))
    season_length <- as.integer(season_end_date) - as.integer(season_start_date)
    remaining_length <- as.integer(season_end_date) - as.integer(last_game_date)
    expected_mean<-2.835184
  } else {
    expected_mean<-NULL
    season_percent <- NULL
  }

  for(day in unique(schedule$Date)){
    d<-as.Date(day, origin="1970-01-01")
    if(regress){
      #Adjust regress to mean
      season_percent <- (remaining_length - as.integer(season_end_date - as.Date(d)))/season_length
    }

    preds<-todayDC(today=d, schedule = schedule, season_percent = season_percent, expected_mean = expected_mean, ...)
    preds$Date <- d
    odds_table<-rbind(odds_table, preds)
  }
  odds_table$Date<-schedule$Date

  if(odds){
    return(odds_table)
  }

  summary_results <- simulateSeasonParallel(odds_table = odds_table, nsims = nsims, scores = scores, schedule = schedule)

  return(summary_results)
}

tau_singular <- function(xx, yy, lambda, mu, rho) {
  if (xx == 0 & yy == 0) {
    return(1 - (lambda * mu * rho))
  } else if (xx == 0 & yy == 1) {
    return(1 + (lambda * rho))
  } else if (xx == 1 & yy == 0) {
    return(1 + (mu * rho))
  } else if (xx == 1 & yy == 1) {
    return(1 - rho)
  } else {
    return(1)
  }
}

#' Tau function
#' @description Used in dixon coles to adjust low scores
#'
#' @param xx Away Goal value for adjustment factor calculation
#' @param yy Home Goal value for adjustment factor calculation
#' @param lambda Home goal expected for adjustment factor calcuation
#' @param mu Away Goal expected for adjustment factor calculation
#' @param rho the factor for adjustment calculations
#'
#' @export
tau <- Vectorize(tau_singular, c('xx', 'yy', 'lambda', 'mu'))

#' Fast Dixon-Coles model fitting 'm'.
#'
#' @description Produces a DC model
#'
#' @param scores the historical scores to evaluate
#' @param currentDate (for date weight adjustment)
#' @param xi agressiveness of date weighting
#'
#' @export
#' @return a model 'm' of dixon coles type parameters.
getM <- function(scores=HockeyModel::scores, currentDate = Sys.Date(), xi=0.00426) {
  df.indep <- data.frame(
    Date = c(scores$Date, scores$Date),
    Weight = c(DCweights(dates = scores$Date, currentDate = currentDate, xi = xi), DCweights(dates = scores$Date, currentDate = currentDate, xi = xi)),
    Team = as.factor(c(as.character(scores$HomeTeam), as.character(scores$AwayTeam))),
    Opponent = as.factor(c(as.character(scores$AwayTeam), as.character(scores$HomeTeam))),
    Goals = c(scores$HomeGoals, scores$AwayGoals),
    Home = c(rep(1, nrow(scores)), rep(0, nrow(scores)))
  )
  #df.indep <- df.indep[df.indep$Weight > 1e-8,]
  #Using a (+0) to remove intercept and give a value for each team instead of assuming 'Anaheim Ducks' = 0 (reference)
  m <- stats::glm(Goals ~ Team + Opponent + Home + 0,
                  data = df.indep,
                  weights = df.indep$Weight,
                  family = stats::poisson(link = log),
                  start = rep(0.01, length(unique(df.indep$Team))*2),
                  model = FALSE
  )
  m<-cleanModel(m)  #reduce M size
  return(m)
}

#' Generate a 'rho' factor for low scoring games
#'
#' @param m result from getM
#' @param scores the historical scores to evaluate
#'
#' @return a numeric value (typically -0.5 to 0)
#' @export
getRho <- function(m = HockeyModel::m, scores=HockeyModel::scores) {
  if (is.null(m)){
    getM(scores)
  }
  expected <- stats::fitted(m)
  home.expected <- as.vector(expected[1:nrow(scores)])
  away.expected <- as.vector(expected[(nrow(scores) + 1):(nrow(scores) * 2)])
  weights<-m$data$Weight[1:nrow(scores)]

  DCoptimRhoFn.fast <- function(par) {
    rho <- par[1]
    DClogLik(y1 = scores$HomeGoals, y2 = scores$AwayGoals, mu = home.expected, lambda = away.expected, rho = rho, weights = weights)
  }

  res <- stats::optim(par = c(-0.1),
                      fn = DCoptimRhoFn.fast,
                      #control = list(fnscale = -1),
                      method = "BFGS")
  return(res$par)

  #of course, res$par is rho. Ranges from -0.2779 for last decade, -0.175 for 20152016 or 0.09 fo the whole league's history
}

#' DC Predict home/draw/away win
#'
#' @description Using Dixon Coles technique, predict odds each of home win, draw, and away win.
#'
#' @param m result from getM
#' @param rho rho from getRho
#' @param home home team
#' @param away away team
#' @param maxgoal max number of goals per team
#' @param scores optional, if not supplying m & rho, scores used to calculate them.
#' @param expected_mean the mean lambda & mu, used only for regression
#' @param season_percent the percent complete of the season, used for regression
#'
#' @return a list of home win, draw, and away win probability
#' @export
DCPredict <- function(home, away, m = HockeyModel::m, rho = HockeyModel::rho, maxgoal = 8, scores = HockeyModel::scores, expected_mean=NULL, season_percent=NULL) {
  if(is.null(m)){
    m <- getM(scores = scores)
  }
  if(is.null(rho)){
    rho <- getRho(m=m, scores=scores)
  }

  # Expected goals home
  lambda <- try(stats::predict(m, data.frame(Home = 1, Team = home, Opponent = away), type = "response"), TRUE)

  # Expected goals away
  mu<-try(stats::predict(m, data.frame(Home = 0, Team = away, Opponent = home), type = "response"), TRUE)

  if(!is.numeric(lambda)){
    lambda<-DCPredictErrorRecover(team = home, opponent = away, homeiceadv = TRUE)
  }
  if(!is.numeric(mu)){
    mu<-DCPredictErrorRecover(team = away, opponent = home, homeiceadv = FALSE)
  }

  if(!is.null(expected_mean) & ! is.null(season_percent)) {
    lambda <- lambda * (1-1/3 * season_percent) + expected_mean * (1/3 * season_percent)
    mu <- mu * (1-1/3 * season_percent) + expected_mean * (1/3 * season_percent)
  }

  probability_matrix <- stats::dpois(0:maxgoal, lambda) %*% t(stats::dpois(0:maxgoal, mu))

  scaling_matrix <- matrix(tau(c(0, 1, 0, 1), c(0, 0, 1, 1), lambda, mu, rho), nrow = 2)
  probability_matrix[1:2, 1:2] <- probability_matrix[1:2, 1:2] * scaling_matrix

  HomeWinProbability <- sum(probability_matrix[lower.tri(probability_matrix)])
  DrawProbability <- sum(diag(probability_matrix))
  AwayWinProbability <- sum(probability_matrix[upper.tri(probability_matrix)])

  #Simple Adjust for underpredicting odds
  HomeWinProbability <- HomeWinProbability * (0.43469786 / 0.4558628)
  AwayWinProbability <- AwayWinProbability * (0.33333333 / 0.3597192)
  DrawProbability <- DrawProbability * (0.2319688 / 0.1755118)
  odds <- normalizeOdds(c(HomeWinProbability, DrawProbability, AwayWinProbability))

  return(odds)
}

#' DC Weight
#'
#' @param dates list of dates to calculate weights.
#' @param currentDate date from which to calculate weight
#' @param xi tuning factor
#'
#' @return list of weights coresponding to dates
#' @keywords internal
DCweights <- function(dates, currentDate = Sys.Date(), xi = 0.00426) {
  datediffs <- dates - as.Date(currentDate)
  datediffs <- as.numeric(datediffs * -1)
  w <- exp(-1 * xi * datediffs)
  w[datediffs <= 0] <- 0  #Future dates should have zero weights
  return(w)
}

DClogLik <- function(y1, y2, lambda, mu, rho = 0, weights = NULL) {
  # rho=0, independence y1 home goals y2 away goals mu:expected Home, lambda: expected Away
  t <- tau(y1, y2, lambda, mu, rho)
  loglik <- log(t) + log(stats::dpois(y1, lambda)) + log(stats::dpois(y2, mu))
  if (is.null(weights)) {
    return(sum(loglik, na.rm = TRUE))
  } else {
    return(sum(loglik * weights, na.rm = TRUE))
  }
}

cleanModel <- function(cm) {
  #from http://www.win-vector.com/blog/2014/05/trimming-the-fat-from-glm-models-in-r/
  cm$y <- c()
  cm$model <- c()

  cm$residuals <- c()
  cm$effects <- c()
  cm$qr$qr <- c()
  cm$linear.predictors <- c()
  cm$weights <- c()
  cm$prior.weights <- c()

  cm
}

DCPredictErrorRecover<-function(team, opponent, homeiceadv = FALSE, m = HockeyModel::m){
  teamlist<-unique(m$data$Team)
  opponentlist<-unique(m$data$Opponent)

  if(homeiceadv){
    homeice<-m$coefficients['Home']
  } else {
    homeice<-0
  }

  if(!(team %in% teamlist) & !(opponent %in% opponentlist)){
    lambda <- NA
  } else if(!(team %in% teamlist)){
    teamp<-min(m$coefficients[grep('Team', names(m$coefficients))])  # lowest goals scored for new team
    opponentp<-m$coefficients[paste0('Opponent', opponent)]

    lambda<-exp(teamp+opponentp+homeice)
  } else if (!(opponent %in% opponentlist)){
    teamp<-m$coefficients[paste0('Team', team)]
    opponentp<-max(m$coefficients[grep('Opponent', names(m$coefficients))])  # most goals allowed for new team

    lambda<-exp(teamp+opponentp+homeice)
  } else {
    lambda <- NA
  }

  if(is.na(lambda)){
    if(homeiceadv){
      lambda <- 3.319624 #Historical home goals
    } else {
      lambda <- 2.827417 #Historical away goals
    }
  }

  return(unname(lambda))
}

#' DC Predict Multiple Days
#'
#' @description For catching up on daily predictions
#'
#' @param start First day to predict. Default start of season
#' @param end Last day to predict. Default today
#' @param scores HockeyModel::scores
#' @param schedule hockeyModel::schedule
#' @param filedir Where to save prediction files.
#' @param ... Additional parameters to pass to dcRealSeasonPredict
#'
#' @return true, if successful
#' @export
dcPredictMultipleDays<-function(start=as.Date("2018-10-03"), end=Sys.Date(), scores=HockeyModel::scores, schedule=HockeyModel::schedule, filedir = "./prediction_results", ...){

  if(!dir.exists(filedir)){
    dir.create(filedir, recursive = TRUE)
  }

  predict_dates<-seq(from = end, to = start, by = -1)

  schedule$Date<-as.Date(schedule$Date)

  message("Running predictions for ", length(predict_dates), " day(s).")
  for(day in predict_dates){
    d<-as.Date(day, origin="1970-01-01")
    message('Predictions as of: ', d)
    score<-scores[scores$Date < day,]
    score<-score[score$Date > as.Date("2008-08-01"),]
    sched<-schedule[schedule$Date >= day,]
    m.day<-getM(scores = score, currentDate = d)
    rho.day<-getRho(m = m.day, scores = score)
    preds<-NULL
    preds<-tryCatch(expr = {
      message("Predicting with Loopless Sim")
      #remainderSeasonDC(nsims=1e5, scores=score, schedule = sched, regress = TRUE)
      loopless_sim(nsims = 1e5, scores = score, schedule = sched, rho = rho.day, m= m.day)
    },
    error = function(error) {
      message('An error occurred:')
      message(error)
      return(NULL)
    })
    if(!is.null(preds) & 'summary_results' %in% names(preds)){
      message('Saving Prediction file...')
      saveRDS(preds$summary_results, file = file.path(filedir, paste0(d, '-predictions.RDS')))
    } else {
      message('An error occurred, retrying ', d, '.')
      preds<-NULL
      preds<-tryCatch(expr = {
          message("Predicting with Old Version Sim")
          remainderSeasonDC(nsims=1e5, scores=score, schedule = sched, regress = TRUE)
        }, error = function(error) {
          message('An error occurred:')
          message(error)
          return(NULL)
        })
      if(!is.null(preds) & 'summary_results' %in% names(preds)){
        message('Saving Prediction file...')
        saveRDS(preds$summary_results, file = file.path(filedir, paste0(d, '-predictions.RDS')))
      } else {
        message('An Error Occurred. Continuing to next day...')
      }
    }
    gc(verbose = FALSE)
  }

  return(TRUE)
}


#' Get Season Metrics
#'
#' @description Calculates the Log Loss and Accuracy of the model by re-estimating m and rho daily and creating game odds
#'
#' @param schedule HockeyModel::schedule used to help with calculations
#' @param scores HockeyModel::scores used to compare to predictions
#'
#' @return a list of log loss and accuracy for the season
#' @export
getSeasonMetricsDC<-function(schedule = HockeyModel::schedule, scores = HockeyModel::scores){
  sched<-schedule
  sched$Home.WLD<-sched$Away.WLD<-sched$Draw.WLD<-sched$Home.WL<-sched$Away.WL<-sched$Result<-NA
  season.sofar<-scores[scores$Date > "2018-10-01", ]

  for (day in as.Date(unique(season.sofar$Date))) {
    d<-as.Date(day, origin="1970-01-01")
    message('Results as of: ', d)
    score<-scores[scores$Date < day,]
    score<-score[score$Date > as.Date("2008-08-01"),]
    m.day<-getM(scores = score, currentDate = d)
    rho.day<-getRho(m = m.day, scores = score)

    p<-todayDC(today = d, rho = rho.day, m = m.day)


    sched[sched$Date == d, "Home.WLD"]<-p$HomeWin
    sched[sched$Date == d, "Away.WLD"]<-p$AwayWin
    sched[sched$Date == d, "Draw.WLD"]<-p$Draw
    sched[sched$Date == d, "Result"]<-season.sofar[season.sofar$Date == d, "Result"]
  }

  sched$Home.WL<-(sched$Home.WLD/(sched$Home.WLD + sched$Away.WLD))*sched$Draw.WLD + sched$Home.WLD
  sched$Away.WL<-(sched$Away.WLD/(sched$Home.WLD + sched$Away.WLD))*sched$Draw.WLD + sched$Away.WLD

  sched<-sched[stats::complete.cases(sched), ]

  logloss<-logLoss(predicted = sched$Home.WL, actual = sched$Result)
  accuracy <- accuracy(predicted = sched$Home.WL>0.5, actual = sched$Result > 0.5)

  return(list("LogLoss" = logloss, "Accuracy" = accuracy))
}
