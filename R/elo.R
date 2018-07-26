#Hosts elo specific functions. Many copied from my work from pbulsink.github.io
#see https://fivethirtyeight.com/features/how-we-calculate-nba-elo-ratings/
# Season reversion = 1505
# New Teams = 1300
# k = MOV * K where K is set and k is for the game. K = 20 for NFL, NBA, less for NHL?
# Margin of VictoryNBA = ((MOV + 3)^0.8)/(7.5 + 0.006 * elodiff) where elodiff = abs(elohome - eloaway including home court adv.)
# MOV NFL = ln(MOV+1) * (2.2/(elodiff)*0.001 + 2.2)
# regression NFL = 1/3 to mean
# regression NBA = 1/4 to mean
#see https://fivethirtyeight.com/features/introducing-nfl-elo-ratings/
#see
# Home adv = 35 pts
# K (no MOV) = 8

# try k = k*(1-2^(-(elodiff*0.01)*mov))
#win percent includes win plus half of draw/ot percent (15% of games historically, 23.6 % of games since 20072008, set at 11.8% per team).

updateELO <- function(){

}

plotELO <- function(){NULL}

todayELO <- function(){NULL}

playoffELO <- function(){NULL}

#' Calculate the win chance percent for HomeTeam
#'
#' @param home_rank The ranking of the Home Team.
#' @param away_rank The ranking of the Away Team.
#' @param h_adv The home advantage (in ranking points). Default: 0
#'
#' @return A number between 0 and 1 corresponding to the win chances of the Home Team.
#' @keywords internal
predictEloResult <- function(home_rank, away_rank, h_adv=0) {
  return(1/(1 + (10^((away_rank - (home_rank+h_adv))/400))))
}

newRankings<-function(home_rank, away_rank, result, diff=NULL, h_adv=35, k=8){
  if (!is.null(diff)){
    elodiff <- away_rank - (home_rank+h_adv)
    k<-k*(1-2^(-(0.5 + elodiff*0.005)*diff))
  }
  p<-predictEloResult(as.numeric(home_rank), as.numeric(away_rank), h_adv)
  h_rank <- as.numeric(home_rank) + k * (as.numeric(result) - p)
  a_rank <- as.numeric(away_rank) + k * ((1 - as.numeric(result)) - (1 - p))
  return(c(h_rank, a_rank))
}

#calculate many seasons of elo
calculateEloRatings <- function(schedule, ratings_history = elos, k = 8, mean_value = 1505, new_teams = 1300,  regress_strength=3, home_adv=35) {
  # Ensuring Opts are ok.
  stopifnot(ncol(schedule) == 5, nrow(schedule) > 0)

  schedule$HomeTeam <- as.character(schedule$HomeTeam)
  schedule$AwayTeam <- as.character(schedule$AwayTeam)
  team_names = unique(c(schedule$HomeTeam, schedule$AwayTeam))
  nteams <- length(team_names)

  if (is.null(ratings_history)) {
    ratings_history <- data.frame("Date"=as.Date(schedule[1,"Date"] -1))
  }

  stopifnot(is.numeric(k))
  stopifnot(is.numeric(mean_value))
  stopifnot(is.numeric(new_teams))

  # Massage Data & Extract Extras
  game_dates <- sort(unique(schedule$Date))
  split_dates <- splitDates(game_dates)

  stopifnot(length(splitDates) > 0)


  if (length(split_dates) >= 2) {
    #For more than one season, use a progress bar. Can be a long calculation
    pb<-utils::txtProgressBar(min = 0, max = length(split_dates), initial = 0)

    for (i in c(1:(length(split_dates)-1))) {


      newseason<-.eloSeason(schedule=schedule, dates=split_dates[[i]], ratings = ratings_history[nrow(ratings_history),,drop=FALSE], new_teams = new_teams, k=k, home_adv = home_adv)

      ifelse (newseason$newteam, ratings_history <- merge(ratings_history, newseason$ratings, all=TRUE), ratings_history<-rbind(ratings_history, newseason$ratings, make.row.names=FALSE))

      #Regress to mean. Teams not playing in a season are given NA
      if (regress_strength != 0){
        ratings_history[nrow(ratings_history)+1,]<-NA
        ratings_history[nrow(ratings_history), "Date"] <- (split_dates[[i+1]][1]-1)
        ratings_history[nrow(ratings_history), newseason$teams] <- (ratings_history[(nrow(ratings_history)-1), newseason$teams] * regress_strength + mean_value)/(regress_strength + 1)
      }

      utils::setTxtProgressBar(pb,i)
    }
  }

  #One (last) season
  newseason<-.eloSeason(schedule=schedule, dates=split_dates[[length(split_dates)]], ratings = ratings_history[nrow(ratings_history),,drop=FALSE], new_teams = new_teams, k=k, home_adv = home_adv)
  ifelse (newseason$newteam, ratings_history <- merge(ratings_history, newseason$ratings, all=TRUE), ratings_history<-rbind(ratings_history, newseason$ratings, make.row.names=FALSE))


  return(ratings_history)
}

#calculate 1 season worth of elo
.eloSeason <- function(schedule, dates, ratings, new_teams, k, home_adv) {
  newteam<-FALSE
  teams<-character()
  for (i in c(1:length(unique(dates)))){
    s<-schedule[(schedule$Date == as.Date(dates[i])),]

    h<-make.names(s[,"HomeTeam"])
    v<-make.names(s[,"AwayTeam"])
    teams<-unique(c(teams,h,v))

    if (length(teams[!(teams %in% names(ratings))]) > 0){
      newteam<-TRUE
      ratings<-cbind(ratings, as.data.frame(stats::setNames(replicate((length(teams[!(teams %in% names(ratings))])), new_teams, simplify=FALSE), teams[!(teams %in% names(ratings))])))
    }

    newelos<-ratings[nrow(ratings), (!names(ratings) %in% "Date")]

    #hack to replace new (formally dropped out teams) as a new team with score new_teams
    newelos[,c(h,v)][is.na(newelos[,c(h,v)])]<-new_teams
    newrank<-newRankings(home_rank = newelos[1,h], away_rank=newelos[1,v], result=s[,"Result"], k=k, h_adv = home_adv, diff=s[,"Diff"])

    ngames<-length(h)
    newelos[1,h]<-newrank[c(1:ngames)]
    newelos[1,v]<-newrank[c((ngames+1):(2*ngames))]
    newelos$Date<-dates[i]

    ratings<-rbind(ratings, newelos, make.row.names=FALSE)
  }
  seasonreturn<-list("ratings"=ratings, "newteam"=newteam, "teams"=teams)
  return(seasonreturn)
}

#'Split dates to by season if multiple seasons are calculated together
#'
#' @param game_dates The dates of games to be split by season as a vector of Dates, or as a df with dates in game_dates$Date.
#' @param season_split The annual date by which to split seasons. As string '-MM-DD' format. For NHL, August 1 is chosen, so '-08-01'
#'
#' @return A list of vectors of dates.
#' @keywords internal
splitDates <- function(game_dates, season_split = "-08-01") {
  if (is.data.frame(game_dates)) {
    game_dates <- sort(unique(game_dates$Date))
  }

  stopifnot(class(game_dates) == "Date")

  start_year <- as.numeric(format(game_dates[1], "%Y"))
  end_year <- as.numeric(format(game_dates[length(game_dates)], "%Y"))
  if (end_year - start_year <= 1) {
    return(list(game_dates))
  }
  split_dates <- rep(NULL, end_year - start_year)
  for (i in c(1:end_year - start_year)) {
    s <- game_dates[game_dates >= as.Date(paste0(i + start_year - 1, season_split)) & game_dates < as.Date(paste0(i + start_year, season_split))]
    if (!length(s) == 0) {
      split_dates[[i]] <- s
    }
  }

  # This removes null (unfilled) 'years' in the data. I'm looking at you, '2005'.
  split_dates <- split_dates[!sapply(split_dates, is.null)]

  return(split_dates)
}