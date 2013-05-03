{-# CFILES hsgclosure.c #-}
import GI.Gtk hiding (main)
import qualified GI.Gtk as Gtk
import qualified GI.Gio as Gio

import Control.Monad (forM_)

import Foreign (nullPtr)

-- A fancy notation for making signal connections easier to read.
(<!>) obj cb = cb obj

main = do
	gtk_init nullPtr nullPtr

	win <- windowNew WindowTypeToplevel
        win <!> onWidgetDestroy $ do
                  putStrLn "Closing the program"
                  mainQuit

        grid <- gridNew
        orientableSetOrientation grid OrientationVertical
        containerAdd win grid

        label <- labelNew "Test"
        widgetShow label
        label <!> onLabelActivateLink $ \uri -> do
                      putStrLn $ uri ++ " clicked."
                      return True -- Link processed, do not open with
                                  -- the browser
        containerAdd grid label

        button <- buttonNewWithLabel "Click me!"
        button <!> onButtonClicked $
                labelSetMarkup label "This is <a href=\"http://www.gnome.org\">a test</a>"
        containerAdd grid button

        ids <- stockListIds
        forM_ ids putStrLn

        infos <- Gio.appInfoGetAll
        forM_ infos $ \info -> do
          name <- Gio.appInfoGetName info
          exe <- Gio.appInfoGetExecutable info
          putStrLn $ "name: " ++ name
          putStrLn $ "exe: " ++ exe
          putStrLn ""

	widgetShowAll win
	Gtk.main
