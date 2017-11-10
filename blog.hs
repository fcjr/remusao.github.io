#! /usr/bin/env stack
{-
stack --resolver lts-9.12 --install-ghc runghc
  --package Glob
  --package async
  --package blaze-html
  --package pandoc
  --package wai-app-static
  --package fsnotify
  --package time
  --package stitch
-}

{-# LANGUAGE PackageImports #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NamedFieldPuns #-}

import Control.Concurrent.Chan (Chan, newChan, getChanContents)
import Control.Concurrent.MVar (newMVar, withMVar)
import Control.Monad (foldM_, foldM)
import System.FilePath (takeExtension, takeBaseName)
import Text.Printf (printf)
import Data.List (sortBy)
import Data.Function (on)
import System.Environment (getArgs)
import qualified Data.Map as M

import "filemanip" System.FilePath.Glob (namesMatching)
import Data.Time.Clock (getCurrentTime)

import Network.URI.Encode (encode)

import Control.Concurrent.Async (concurrently_)

-- File Parsing
import Text.Pandoc
import Text.Pandoc.Walk (query)

-- Watch File Modifications
import System.FSNotify

-- HTML Templating
import Text.Blaze.Html
import Text.Blaze.Html.Renderer.String
import qualified Text.Blaze.Html5 as H
import qualified Text.Blaze.Html5.Attributes as A

-- CSS Generation
import Stitch
import Stitch.Render

-- Static HTTP File Server
import Network.Wai.Handler.Warp (run)
import Network.Wai.Application.Static


css :: Html
css = H.style $ H.text $ renderCSSWith basic $ -- use compressed
  -- Style body
  "body" ? do
    -- Text style and general layout
    "background" .= "#ffffff"
    "color" .= "#2e3436"

    "font-family" .= "Verdana,sans-serif"
    "font-size" .= "18px"
    "text-rendering" .= "optimizeLegibility"

    "line-height" .= "1.3"
    "margin" .= "0 auto"
    "max-width" .= "40em"
    "padding" .= "0 0.5em"
    "text-align" .= "justify"

    -- Style Blog Header
    "header" ? do
      "border-bottom" .= "thin solid #d3d7cf"
      -- margin-bottom: 30px;
      -- padding: 12px 0px 12px 0px;

      "h1" ? do
        "font" .= "inherit"
        "font-size" .= "2.5em"
        "line-height" .= "3em"
        "text-align" .= "center"

      "a" ? do
        "color" .= "#63007d"
        "text-decoration" .= "none"
        "display" .= "block"
        "border" .= "none"

    "footer" ? do
      "border-top" .= "thin solid #d3d7cf"
      "color" .= "#555"
      "font-size" .= "12px"
      "margin-top" .= "30px"
      "padding" .= "12px 0px 12px 0px"

    -- Style Blog Content
    "main" ? do
      -- Style sharing buttons
      "div.share" ? do
        "ul" ? do
          "padding" .= "0 0 0 1em"
          "padding-left" .= "0"
          "text-align" .= "right"

          "img" ? do
            "width" .= "42px"

          "li" ? do
            "display" .= "inline"
            "margin" .= "0px 5px"

      "img.logo" ? do
        "width" .= "1em"
        "height" .= "1em"
        "display" .= "inline"
        "margin" .= "0px 1em"

      "section.header" ? do
        "color" .= "#555"
        "font-style" .= "italic"
        "display" .= "block"

      "h1" ? do
        "font" .= "inherit"
        "font-size" .= "1.7em"
        "line-height" .= "1.5em"

      "a" ? do
        "color" .= "#3465a4"
        "text-decoration" .= "none"

      "a:visited" ? do
        "color" .= "#75507b"

      "ul" ? do
        "margin" .= "1.0em 0"
        "padding" .= "0 0 0 1em"
        "padding-left" .= "2em"

        "li" ? do
          "margin" .= "4px 0"

      "ul.index" ? do
        "list-style" .= "none"
        "padding-left" .= "1em"

      ".index" ? do
        "color" .= "#555"
        "font-style" .= "italic"
        "display" .= "inline"

      "article" ? do
        "h2" ? do
          "font-size" .= "1.3em"
          "line-height" .= "1.2em"
          "margin" .= "1.5em 0px 0px 0px"

        ".figure" ? do
          "text-align" .= "center"

        "figcaption" ? do
          "text-align" .= "center"
          "font-style" .= "italic"
          "color" .= "#696f72"
          "line-height" .= "2em"

        "img" ? do
          "display" .= "block"
          "margin-left" .= "auto"
          "margin-right" .= "auto"
          "text-align" .= "center"

        "blockquote" ? do
          "border-left" .= "thin solid #d3d7cf"
          "margin" .= "10px"
          "padding" .= "0 0 0 1em"
          "color" .= "#555555"
--
-- main .inline-math {
--     display: inline;
-- }

      -- Style source code
        "code" ? do
          "font-family" .= "Menlo,Monaco,Consolas,\"Liberation Mono\",\"Courier New\",monospace"
          "background-color" .= "#f3f4f5"

        "code.sourceCode" ? do
          "overflow-x" .= "auto" -- Make code block scrollable
          "display" .= "block"
          "padding" .= "8px"
          "margin-bottom" .= "1em"

          -- Colors
          ".al" ? do { "color" .= orange; "font-weight" .= "bold"; }   -- Alert
          ".an" ? do { "color" .= violet; "font-weight" .= "bold"; }   -- Annotation
       -- ".at" ? do }                                                    -- Attribute
          ".av" ? do { "color" .= orange; }
          ".bn" ? do { "color" .= cyan; }                            -- BaseNTok
          ".cf" ? do { "color" .= violet; }                            -- Control Flow
          ".ch" ? do { "color" .= cyan; }                            -- Char
          ".co" ? do { "color" .= base01; "font-style" .= "italic"; }  -- CommentTok
          ".cv" ? do { "color" .= orange; }                            -- Comment Var
          ".dt" ? do { "color" .= yellow; }                            -- DataType
          ".dv" ? do { "color" .= cyan; }                            -- Decimal Value
          ".er" ? do { "color" .= red; "font-weight" .= "bold"; }   -- Error
          ".ex" ? do { "color" .= orange; }                            -- Extension
          ".fl" ? do { "color" .= cyan; }                            -- Float
          ".fu" ? do { "color" .= blue; }                            -- Function
          ".im" ? do { "color" .= blue; }                            -- Import
          ".kw" ? do { "color" .= green; "font-weight" .= "bold"; }   -- KeyWord
          ".op" ? do { "color" .= orange; }                            -- Builtin
          ".op" ? do { "color" .= orange; }                            -- Operator
          ".ot" ? do { "color" .= orange; }                            -- Other
       -- ".re" ? do }                                                    -- RegionMarker
          ".sc" ? do { "color" .= cyan; "font-weight" .= "bold"; }  -- Special Char
          ".ss" ? do { "color" .= cyan; }                            -- Verbatim String
          ".st" ? do { "color" .= cyan; }                            -- String
          ".va" ? do { "color" .= orange; }                            -- Variable
          ".vs" ? do { "color" .= cyan; }                            -- Special String
          ".wa" ? do { "color" .= red; "font-weight" .= "bold"; }  -- Warning
  where
    base0 =   "#839496"
    base00 =  "#657b83"
    base01 =  "#586e75"
    base02 =  "#073642"
    base03 =  "#002b36"
    base1 =   "#93a1a1"
    base2 =   "#eee8d5"
    base3 =   "#fdf6e3"
    blue =    "#268bd2"
    cyan =    "#2aa198"
    green =   "#859900"
    magenta = "#d33682"
    orange =  "#cb4b16"
    red =     "#dc322f"
    violet =  "#6c71c4"
    yellow =  "#b58900"


blogDomain :: String
blogDomain = "https://remusao.github.io/"

blogTitle :: String
blogTitle = "Simplex Sigillum Veri"


data Sharing = Sharing
  { href :: String
  , alt :: String
  , img :: String
  }


sharing :: String -> String -> Html
sharing url title = H.ul $ mconcat $ map button [
    Sharing {
        href = "https://www.facebook.com/sharer/sharer.php?u=%s&t=%s"
      , alt = "Share on Facebook"
      , img = "Facebook.svg"
    },
    Sharing {
        href = "http://twitter.com/share?url=%s&text=%s&via=Pythux"
      , alt = "Tweet"
      , img = "Twitter.svg"
    },
    Sharing {
        href = "https://getpocket.com/save?url=%s&title=%s"
      , alt = "Add to Pocket"
      , img = "Pocket.svg"
    },
    Sharing {
        href = "https://news.ycombinator.com/submitlink?u=%s&t=%s"
      , alt = "Submit to Hacker News"
      , img = "HackerNews.svg"
    },
    Sharing {
        href = "http://www.reddit.com/submit?url=%s&title=%s"
      , alt = "Submit to Reddit"
      , img = "Reddit.svg"
    }
  ]
  where
    urlEncoded = encode url
    titleEncoded = encode title
    button Sharing { href, alt, img } =
      H.li $ H.a
        ! A.href (H.stringValue $ printf href urlEncoded titleEncoded)
        ! A.title (H.stringValue alt)
        ! A.target "_blank" $
          H.img
            ! A.alt (H.stringValue alt)
            ! A.src (H.stringValue $ "/images/social_flat_rounded_rects_svg/" ++ img)


defaultTemplate :: String -> Bool -> Html -> Html
defaultTemplate title math post = H.docTypeHtml $ do
  H.head $ do
    H.meta H.! A.charset "utf-8"
    H.meta H.! A.httpEquiv "x-ua-compatible" H.! A.content "ie=edge"
    H.meta H.! A.name "viewport" H.! A.content "width=device-width, initial-scale=1"
    H.link H.! A.rel "shortcut icon" H.! A.type_ "image/x-icon" H.! A.href "../images/favicon.ico"
    H.title $ H.string $ blogTitle ++ " - " ++ title
    css
    if math
       then do
         H.link H.! A.rel "stylesheet" H.! A.href "/katex/katex.css"
         H.script "" H.! A.src "/katex/katex.js"
       else ""
  H.body $ do
    H.header $ H.h1 $ H.a H.! A.href "../" $ H.span "Simplex Sigillum Veri"
    H.main $ do
      H.h1 $ H.string title
      post


postTemplate :: Html -> Post -> Html
postTemplate html Post { title, url, date, math, pandoc, readingTime } = defaultTemplate title math $ do
  H.section ! A.class_ "header" $ H.div $ do
    H.string date
    H.string " | "
    H.em $ H.string $ printf "Reading time: ~%i minutes" readingTime
  H.article html
  H.footer $ H.div ! A.class_ "share" $ sharing (printf "%s%s" blogDomain url) title


indexTemplate :: Html -> Html
indexTemplate html = defaultTemplate "Posts" False $ do
  html
  H.footer ""


collectStr :: Inline -> [String]
collectStr (Str s) = [s]
collectStr _ = []


getDocumentTitle, getDocumentAuthor, getDocumentDate, getDocumentLogo :: Pandoc -> String
getDocumentTitle (Pandoc meta _) = unwords $ query collectStr (docTitle meta)
getDocumentAuthor (Pandoc meta _) = unwords $ query collectStr (docAuthors meta)
getDocumentDate (Pandoc meta _) = unwords $ query collectStr (docDate meta)
getDocumentLogo (Pandoc meta _) =
  case lookupMeta "logo" meta of
    Nothing -> defaultIcon
    Just m -> getIcon $ concat $ query collectStr m
  where
    defaultIcon = getIcon ""

    getIcon "python" = "/images/python.svg"
    getIcon "haskell" = "/images/haskell.svg"
    getIcon "c++" = "/images/cpp.svg"
    getIcon "raspberry" = "/images/raspberry-pi.svg"
    getIcon "ocaml" = "/images/ocaml.svg"
    getIcon "html5" = "/images/html5.svg"
    getIcon "julia" = "/images/julia.svg"
    getIcon "hashcode" = "/images/hashcode.png"
    getIcon "xmonad" = "/images/xmonad.svg"
    getIcon "pi" = "/images/pi.svg"
    getIcon _ = "/images/haskell.svg"


getApproxReadingTime :: Pandoc -> Int
getApproxReadingTime pandoc = max (textLength `div` 150) 1
  where
    textLength = length $ concatMap words $ query collectText pandoc
    collectText (Str s) = [s]
    collectText (Code _ s) = [s]
    collectText _ = []

data Post = Post
  { html :: String
  , title :: String
  , author :: String
  , date :: String
  , url :: String
  , math :: Bool
  , pandoc :: Pandoc
  , logo :: String
  , readingTime :: Int
  } deriving Show


hasMath :: Pandoc -> Bool
hasMath = not . null . query collectMath
  where
    collectMath (Math _ _) = [True]
    collectMath _ = []


generatePost :: String -> String -> Maybe Post
generatePost content url =
  case readMarkdown readerOpt content of
    Left _ -> Nothing
    Right parsed ->
      let
        title = getDocumentTitle parsed
        author = getDocumentAuthor parsed
        date = getDocumentDate parsed
        html = renderHtml $ postTemplate (writeHtml writerOpt parsed) post
        math = hasMath parsed
        readingTime = getApproxReadingTime parsed
        logo = getDocumentLogo parsed
        post = Post {
            author = author
          , html = html
          , date = date
          , math = math
          , pandoc = parsed
          , title = title
          , readingTime = readingTime
          , logo = logo
          , url = url }
       in Just post
  where
    readerOpt = def
      { readerSmart = True
      }
    writerOpt = def
      { writerTableOfContents = True
      , writerHTMLMathMethod = KaTeX "./katex/katex.css" "./katex/katex.js"
      , writerNumberSections = True
      , writerNumberOffset = [1]
      , writerEmailObfuscation = JavascriptObfuscation
      , writerCiteMethod = Citeproc
      , writerHtml5 = True
      , writerHighlight = True
      , writerTOCDepth = 1
      }


serveSite :: (String -> IO ()) -> IO ()
serveSite logging = do
  logging "Serving HTTP on 0.0.0.0 port 8000..."
  run 8000 (staticApp (defaultFileServerSettings "."))


generateIndex :: [Post] -> Html
generateIndex posts = indexTemplate $
  H.ul ! A.class_ "index" $ mconcat [
    H.li $ do
      H.img ! A.class_ "logo" ! A.src (H.stringValue logo)
      H.a ! A.href (H.stringValue url) $ H.string title
      H.string " - "
      H.string date
      | Post { url, title, date, logo } <- sortBy (flip compare `on` date) posts
  ]

-- Keep track of the current posts in the blog
type Blog = M.Map FilePath Post


getFilePath :: Event -> FilePath
getFilePath (Added f _) = f
getFilePath (Modified f _) = f
getFilePath (Removed f _) = f


isFileAltered :: Event -> Bool
isFileAltered (Added _ _) = True
isFileAltered (Modified _ _) = True
isFileAltered _ = False


updateSite :: (String -> IO ()) -> Blog -> [Event] -> IO Blog
updateSite logging blog newFiles = do
  -- TODO: Parallel for to produce [Post]
  -- TODO: (then) Sequential fold to update the Map
  updatedBlog <- foldM updateBlog blog newFiles
  let posts = M.elems updatedBlog
  writeFile "index.html" $ renderHtml $ generateIndex posts
  logging $ printf "Generating index.html for %i posts..." (length posts)
  return updatedBlog
  where
    updateBlog :: Blog -> Event -> IO Blog
    updateBlog b event
      | isFileAltered event = do
        let f = getFilePath event
        let name = takeBaseName f
        let output = name ++ ".html"
        logging $ printf "Generating %s..." output
        content <- readFile f
        case generatePost content output of
          Nothing -> return b
          Just post -> do
            writeFile output $ html post
            return $ M.alter (
              \case
                Nothing -> Just post
                Just _ -> Just post) name b
      | otherwise = do
        let name = takeBaseName (getFilePath event)
        return $ M.alter (
            \case
              Nothing -> Nothing
              Just _ -> Nothing) name b


generateSite :: (String -> IO ()) -> Blog -> Chan Event -> IO ()
generateSite logging blog fileModifiedEvents = do
    events <- getChanContents fileModifiedEvents
    foldM_ (\b e -> updateSite logging b [e]) blog events


main :: IO ()
main = do
  -- Thread-safe logging function
  lock <- newMVar ()
  let logging str = withMVar lock (\_ -> putStrLn str)

  -- Create list of posts
  now <- getCurrentTime
  files <- namesMatching "./posts/*.md"

  -- Init blog with all posts
  blog <- updateSite logging M.empty $ fmap (`Added` now) files

  programArgs <- getArgs

  case programArgs of
    ["serve"] -> do
      fileModifiedEvents <- newChan

      -- Watch tree directory
      concurrently_ (generateSite logging blog fileModifiedEvents) $
        withManager $ \mgr -> do
          -- start a watching job (in the background)
          _ <- watchTreeChan
            mgr          -- manager
            "./posts/"   -- directory to watch
            (\e -> takeExtension (getFilePath e) == ".md") -- predicate: TODO filter markdown posts
            fileModifiedEvents

          putStrLn "listening..."
          serveSite logging
    _ -> putStrLn "Done."
