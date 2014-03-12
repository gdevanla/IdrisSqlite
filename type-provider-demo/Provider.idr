module Provider

import Providers

import DB.SQLite.Effect
import Effects

import Database
import Parser

%language TypeProviders

mkDB : ResultSet -> Either String (List (String, Schema))
mkDB [] = pure []
mkDB ([DBText v]::rest) =
  case parse table (toLower v) of
    Left err => Left ( "Couldn't parse schema '" ++ v ++ "'\n" ++ err)
    Right (t, tbl) => [| pure (t, tbl) :: mkDB rest |]
mkDB _ = Left "Couldn't understand SQLite output - wrong type"

getSchemas : (filename : String) -> { [SQLITE ()] } Eff IO (Provider (DB filename))
getSchemas file =
  do resSet <- executeSelect file "SELECT `sql` FROM `sqlite_master`;" [] $
               do sql <- getColumnText 0
                  pure [DBText sql]
     case resSet of
       Left err => pure (Error $ "Error reading '" ++ file ++ "': " ++ (show err))
       Right res => case mkDB res of
                      Left err => pure (Error err)
                      Right db => pure (Provide (MkDB file db))

getRow : (s : Schema) -> { [SQLITE (SQLiteExecuting ValidRow)] } Eff IO (Row s)
getRow s = go 0 s
  where go : Int -> (s : Schema) -> { [SQLITE (SQLiteExecuting ValidRow)] } Eff IO (Row s)
        go i []          = pure []
        go i ((_ ::: ty) :: s) = [| getCol ty :: go (i+1) s |]
          where getCol : (t : SQLiteType) -> { [SQLITE (SQLiteExecuting ValidRow)] } Eff IO (interpSql t)
                getCol TEXT = getColumnText i
                getCol INTEGER = do int <- getColumnInt i
                                    pure (cast int)
                getCol REAL = getColumnFloat i
                getCol (NULLABLE x) = do nullp <- isColumnNull i
                                         if nullp
                                           then pure Nothing
                                           else do val <- getCol x
                                                   pure (Just val)

collectRows : (s : Schema) -> { [SQLITE (SQLiteExecuting ValidRow)] ==>
                                [SQLITE (SQLiteExecuting InvalidRow)] } Eff IO (Table s)
collectRows s = do row <- getRow s
                   case !nextRow of
                     Unstarted => pure $ row :: !(collectRows s)
                     StepFail => pure $ row :: !(collectRows s)
                     StepComplete => pure $ row :: !(collectRows s)
                     NoMoreRows => pure [row]

query : {file : String} -> {db : DB file} -> Query db s ->
        { [SQLITE ()] } Eff IO (Either QueryError (Table s))
query {file=fn} q =
  case !(openDB fn) of
    Left err => pure $ Left err
    Right () =>  -- FIXME should really use binding
      case !(prepareStatement (compileQuery q)) of
        Left err => do cleanupPSFail
                       pure $ Left err
        Right () =>
          case !finishBind of
            Just err => do cleanupBindFail ; return $ Left err
            Nothing =>
              case !executeStatement of
                Unstarted => do rs <- collectRows _
                                finalise
                                closeDB
                                pure (Right rs)
                StepFail => do rs <- collectRows _
                               finalise
                               closeDB
                               pure (Right rs)
                StepComplete => do rs <- collectRows _
                                   finalise
                                   closeDB
                                   pure (Right rs)
                NoMoreRows => do finalise
                                 closeDB
                                 pure (Right [])


-- Local Variables:
-- idris-packages: ("lightyear" "sqlite" "neweffects")
-- End:
 