{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE CPP #-}
#include "boxes.h"

-----------------------------------------------------------------------------
-- |
-- Module      :  Text.PrettyPrint.Boxes
-- Copyright   :  (c) Brent Yorgey 2009
-- License     :  BSD-style (see LICENSE)
-- Maintainer  :  David.Feuer@gmail.com
-- Stability   :  experimental
-- Portability :  portable
--
-- A pretty-printing library for laying out text in two dimensions,
-- using a simple box model.
--
-----------------------------------------------------------------------------
module Text.PrettyPrint.Boxes
    ( -- * Constructing boxes
#ifdef TESTING
      Box(Box, content)
#else
      Box
#endif
    , nullBox
    , emptyBox
    , char
    , text
    , para
    , columns

      -- * Layout of boxes

    , (<>)
    , (<+>)
    , hcat
    , hsep

    , (//)
    , (/+/)
    , vcat
    , vsep

    , punctuateH, punctuateV

    -- * Alignment

#ifdef TESTING
    , Alignment(..)
#else
    , Alignment
#endif

#ifdef TESTING
    , Content(..)
#endif
    , left, right
    , top, bottom
    , center1, center2

    , moveLeft
    , moveRight
    , moveUp
    , moveDown

    , alignHoriz
    , alignVert
    , align

    -- * Inspecting boxes

    , rows
    , cols

    -- * Rendering boxes

    , render
    , printBox

    ) where

#if MIN_VERSION_base(4,11,0)
import Prelude hiding ( (<>), Word )
#elif MIN_VERSION_base(4,8,0)
import Prelude hiding (Word)
#else
import Data.Foldable (Foldable (foldr))
import Data.Monoid (Monoid, mappend, mempty)
import Prelude hiding (foldr)
#endif
import Data.Foldable (toList)

#if MIN_VERSION_base(4,4,0)
import Data.String (words, unwords)
#else
import Data.List (words, unwords)
#endif

#ifdef OVERLOADED_STRINGS
import Data.String (IsString(..))
#endif

import Control.Arrow ((***), first)
import Data.List (foldl', intersperse)

import Data.List.Split (chunksOf)

class Monoid a => IsContent a where
    -- | @cntJustify algn a n xs@ is like 'justifyLeft' and 'justifyRight' combined with alignment.
    cntJustify :: Alignment -> Char -> Int -> a -> a

    cntLength :: a -> Int
    cntSingleton :: Char -> a
    cntTake :: Int -> a -> a
    cntUnlines :: [a] -> a
    cntUnwords :: [a] -> a
    cntWords :: a -> [a]

instance IsContent String where
    cntJustify c b n = glue . (jl (numRev c n) *** jr (numFwd c n)) . split
      where split t = splitAt (numRev c (length t)) $ t
            glue    = uncurry mappend
            jl n' _ | n' <= 0 = mempty
            jl n' x = let y = take n' x in replicate (n' - length y) b ++ y
            jr n' _ | n' <= 0 = mempty
            jr n' x = let y = take n' x in y ++ replicate (n' - length y) b
    cntLength = length
    cntSingleton = (:[])
    cntTake = take
    cntUnlines = unlines
    cntUnwords = unwords
    cntWords = words

-- | The basic data type.  A box has a specified size and some sort of
--   contents.
data Box a = Box { rows    :: Int
                 , cols    :: Int
                 , content :: Content a
                 }
  deriving (Show)

#ifdef OVERLOADED_STRINGS
-- | Convenient ability to use bare string literals as boxes.
instance IsString (Box String) where
  fromString = text
#endif

-- | Data type for specifying the alignment of boxes.
data Alignment = AlignFirst    -- ^ Align at the top/left.
               | AlignCenter1  -- ^ Centered, biased to the top/left.
               | AlignCenter2  -- ^ Centered, biased to the bottom/right.
               | AlignLast     -- ^ Align at the bottom/right.
  deriving (Eq, Read, Show)

-- | Align boxes along their tops.
top :: Alignment
top        = AlignFirst

-- | Align boxes along their bottoms.
bottom :: Alignment
bottom     = AlignLast

-- | Align boxes to the left.
left :: Alignment
left       = AlignFirst

-- | Align boxes to the right.
right :: Alignment
right      = AlignLast

-- | Align boxes centered, but biased to the left/top in case of
--   unequal parities.
center1 :: Alignment
center1    = AlignCenter1

-- | Align boxes centered, but biased to the right/bottom in case of
--   unequal parities.
center2 :: Alignment
center2    = AlignCenter2

-- | Contents of a box.
data Content a = Blank        -- ^ No content.
               | Text a       -- ^ The raw content of the box.
               | Row [Box a]  -- ^ A row of sub-boxes.
               | Col [Box a]  -- ^ A column of sub-boxes.
               | SubBox Alignment Alignment (Box a)
                              -- ^ A sub-box with a specified alignment.
  deriving (Show)

-- | The null box, which has no content and no size.  It is quite
--   useless.
nullBox :: Box a
nullBox = emptyBox 0 0

-- | @emptyBox r c@ is an empty box with @r@ rows and @c@ columns.
--   Useful for effecting more fine-grained positioning of other
--   boxes, by inserting empty boxes of the desired size in between
--   them.
emptyBox :: Int -> Int -> Box a
emptyBox r c = Box r c Blank

-- | A @1x1@ box containing a single character.
char :: IsContent a => Char -> Box a
char c = Box 1 1 (Text (cntSingleton c))

-- | A (@1 x len@) box containing a string of length @len@.
text :: IsContent a => a -> Box a
text t = Box 1 (cntLength t) (Text t)

-- | Paste two boxes together horizontally, using a default (top)
--   alignment.
(<>) :: Box a -> Box a -> Box a
l <> r = hcat top [l,r]

-- | Paste two boxes together horizontally with a single intervening
--   column of space, using a default (top) alignment.
(<+>) :: Box a -> Box a -> Box a
l <+> r = hcat top [l, emptyBox 0 1, r]

-- | Paste two boxes together vertically, using a default (left)
--   alignment.
(//) :: Box a -> Box a -> Box a
t // b = vcat left [t,b]

-- | Paste two boxes together vertically with a single intervening row
--   of space, using a default (left) alignment.
(/+/) :: Box a -> Box a -> Box a
t /+/ b = vcat left [t, emptyBox 1 0, b]

-- | Glue a list of boxes together horizontally, with the given alignment.
hcat :: Foldable f => Alignment -> f (Box a) -> Box a
hcat a bs = Box h w (Row $ map (alignVert a h) bsl)
  where
    (w, h) = sumMax cols 0 rows bsl
    bsl = toList bs

-- | @hsep sep a bs@ lays out @bs@ horizontally with alignment @a@,
--   with @sep@ amount of space in between each.
hsep :: Foldable f => Int -> Alignment -> f (Box a) -> Box a
hsep sep a bs = punctuateH a (emptyBox 0 sep) bs

-- | Glue a list of boxes together vertically, with the given alignment.
vcat :: Foldable f => Alignment -> f (Box a) -> (Box a)
vcat a bs = Box h w (Col $ map (alignHoriz a w) bsl)
  where
    (h, w) = sumMax rows 0 cols bsl
    bsl = toList bs

-- Calculate a sum and a maximum over a list in one pass. If the list is
-- empty, the maximum is reported as the given default. This would
-- normally be done using the foldl library, but we don't want that
-- dependency.
sumMax :: (Num n, Ord b, Foldable f) => (a -> n) -> b -> (a -> b) -> f a -> (n, b)
sumMax f defaultMax g as = foldr go (,) as 0 defaultMax
  where
    go a r n b = (r $! f a + n) $! g a `max` b

-- | @vsep sep a bs@ lays out @bs@ vertically with alignment @a@,
--   with @sep@ amount of space in between each.
vsep :: Foldable f => Int -> Alignment -> f (Box a) -> Box a
vsep sep a bs = punctuateV a (emptyBox sep 0) (toList bs)

-- | @punctuateH a p bs@ horizontally lays out the boxes @bs@ with a
--   copy of @p@ interspersed between each.
punctuateH :: Foldable f => Alignment -> Box a -> f (Box a) -> Box a
punctuateH a p bs = hcat a (intersperse p (toList bs))

-- | A vertical version of 'punctuateH'.
punctuateV :: Foldable f => Alignment -> Box a -> f (Box a) -> Box a
punctuateV a p bs = vcat a (intersperse p (toList bs))

--------------------------------------------------------------------------------
--  Paragraph flowing  ---------------------------------------------------------
--------------------------------------------------------------------------------

-- | @para algn w t@ is a box of width @w@, containing text @t@,
--   aligned according to @algn@, flowed to fit within the given
--   width.
para :: IsContent a => Alignment -> Int -> a -> Box a
para a n t = (\ss -> mkParaBox a (length ss) ss) $ flow n t

-- | @columns w h t@ is a list of boxes, each of width @w@ and height
--   at most @h@, containing text @t@ flowed into as many columns as
--   necessary.
columns :: IsContent a => Alignment -> Int -> Int -> a -> [Box a]
columns a w h t = map (mkParaBox a h) . chunksOf h $ flow w t

-- | @mkParaBox a n s@ makes a box of height @n@ with the text @s@
--   aligned according to @a@.
mkParaBox :: IsContent a => Alignment -> Int -> [a] -> Box a
mkParaBox a n = alignVert top n . vcat a . map text

-- | Flow the given text into the given width.
flow :: IsContent a => Int -> a -> [a]
flow n t = map (cntTake n)
         . getLines
         $ foldl' addWordP (emptyPara n) (map mkWord . cntWords $ t)

data Para a = Para { paraWidth   :: Int
                   , paraContent :: ParaContent a
                   }
data ParaContent a = Block { fullLines :: [Line a]
                           , lastLine  :: Line a
                           }

emptyPara :: Int -> Para a
emptyPara pw = Para pw (Block [] (Line 0 []))

getLines :: IsContent a => Para a -> [a]
getLines (Para _ (Block ls l))
  | lLen l == 0 = process ls
  | otherwise   = process (l:ls)
  where process = map (cntUnwords . reverse . map getWord . getWords) . reverse

data Line a = Line { lLen :: Int, getWords :: [Word a] }

mkLine :: [Word a] -> Line a
mkLine ws = Line (sum (map ((+1) . wLen) ws) - 1) ws

startLine :: Word a -> Line a
startLine = mkLine . (:[])

data Word a = Word { wLen :: Int, getWord  :: a }

mkWord :: IsContent a => a -> Word a
mkWord w = Word (cntLength w) w

addWordP :: Para a -> Word a -> Para a
addWordP (Para pw (Block fl l)) w
  | wordFits pw w l = Para pw (Block fl (addWordL w l))
  | otherwise       = Para pw (Block (l:fl) (startLine w))

addWordL :: Word a -> Line a -> Line a
addWordL w (Line len ws) = Line (len + wLen w + 1) (w:ws)

wordFits :: Int -> Word a -> Line a -> Bool
wordFits pw w l = lLen l == 0 || lLen l + wLen w + 1 <= pw

--------------------------------------------------------------------------------
--  Alignment  -----------------------------------------------------------------
--------------------------------------------------------------------------------

-- | @alignHoriz algn n bx@ creates a box of width @n@, with the
--   contents and height of @bx@, horizontally aligned according to
--   @algn@.
alignHoriz :: Alignment -> Int -> Box a -> Box a
alignHoriz a c b = align a AlignFirst (rows b) c b

-- | @alignVert algn n bx@ creates a box of height @n@, with the
--   contents and width of @bx@, vertically aligned according to
--   @algn@.
alignVert :: Alignment -> Int -> Box a -> Box a
alignVert a r b = align AlignFirst a r (cols b) b

-- | @align ah av r c bx@ creates an @r@ x @c@ box with the contents
--   of @bx@, aligned horizontally according to @ah@ and vertically
--   according to @av@.
align :: Alignment -> Alignment -> Int -> Int -> Box a -> Box a
align ah av r c = Box r c . SubBox ah av

-- | Move a box \"up\" by putting it in a larger box with extra rows,
--   aligned to the top.  See the disclaimer for 'moveLeft'.
moveUp :: Int -> Box a -> Box a
moveUp n b = alignVert top (rows b + n) b

-- | Move a box down by putting it in a larger box with extra rows,
--   aligned to the bottom.  See the disclaimer for 'moveLeft'.
moveDown :: Int -> Box a -> Box a
moveDown n b = alignVert bottom (rows b + n) b

-- | Move a box left by putting it in a larger box with extra columns,
--   aligned left.  Note that the name of this function is
--   something of a white lie, as this will only result in the box
--   being moved left by the specified amount if it is already in a
--   larger right-aligned context.
moveLeft :: Int -> Box a -> Box a
moveLeft n b = alignHoriz left (cols b + n) b

-- | Move a box right by putting it in a larger box with extra
--   columns, aligned right.  See the disclaimer for 'moveLeft'.
moveRight :: Int -> Box a -> Box a
moveRight n b = alignHoriz right (cols b + n) b

--------------------------------------------------------------------------------
--  Implementation  ------------------------------------------------------------
--------------------------------------------------------------------------------

-- | Render a 'Box', suitable for writing to the screen or
--   a file.
render :: IsContent a => Box a -> a
render = cntUnlines . renderBox

-- XXX make QC properties for takeP

-- | \"Padded take\": @takeP a n xs@ is the same as @take n xs@, if @n
--   <= length xs@; otherwise it is @xs@ followed by enough copies of
--   @a@ to make the length equal to @n@.
takeP :: a -> Int -> [a] -> [a]
takeP _ n _      | n <= 0 = []
takeP b n []              = replicate n b
takeP b n (x:xs)          = x : takeP b (n-1) xs

-- | @takePA a n xs@ is like 'takeP', but with alignment.  That is, we
--   imagine a copy of @xs@ extended infinitely on both sides with
--   copies of @a@, and a window of size @n@ placed so that @xs@ has
--   the specified alignment within the window; @justify algn a n xs@
takePA :: Alignment -> a -> Int -> [a] -> [a]
takePA c b n = glue . (takeP b (numRev c n) *** takeP b (numFwd c n)) . split
  where split t = first reverse . splitAt (numRev c (length t)) $ t
        glue    = uncurry (++) . first reverse

numFwd, numRev :: Alignment -> Int -> Int
numFwd AlignFirst    n = n
numFwd AlignLast     _ = 0
numFwd AlignCenter1  n = n `div` 2
numFwd AlignCenter2  n = (n+1) `div` 2
numRev AlignFirst    _ = 0
numRev AlignLast     n = n
numRev AlignCenter1  n = (n+1) `div` 2
numRev AlignCenter2  n = n `div` 2

-- | Generate a string of spaces.
blanks :: IsContent a => Int -> a
blanks n = cntJustify AlignCenter1 ' ' n mempty

-- | Render a box as a list of lines.
renderBox :: IsContent a => Box a -> [a]

renderBox (Box r c Blank)            = resizeBox r c [mempty]
renderBox (Box r c (Text t))         = resizeBox r c [t]
renderBox (Box r c (Row bs))         = resizeBox r c
                                       . merge
                                       . map (renderBoxWithRows r)
                                       $ bs
                           where 
                            merge = foldr (zipWith mappend) (repeat mempty)

renderBox (Box r c (Col bs))         = resizeBox r c
                                       . concatMap (renderBoxWithCols c)
                                       $ bs

renderBox (Box r c (SubBox ha va b)) = resizeBoxAligned r c ha va
                                       . renderBox
                                       $ b

-- | Render a box as a list of lines, using a given number of rows.
renderBoxWithRows :: IsContent a => Int -> Box a -> [a]
renderBoxWithRows r b = renderBox (b{rows = r})

-- | Render a box as a list of lines, using a given number of columns.
renderBoxWithCols :: IsContent a => Int -> Box a -> [a]
renderBoxWithCols c b = renderBox (b{cols = c})

-- | Resize a rendered list of lines.
resizeBox :: IsContent a => Int -> Int -> [a] -> [a]
resizeBox r c = takeP (blanks c) r . map (cntJustify AlignFirst ' ' c)

-- | Resize a rendered list of lines, using given alignments.
resizeBoxAligned :: IsContent a => Int -> Int -> Alignment -> Alignment -> [a] -> [a]
resizeBoxAligned r c ha va = takePA va (blanks c) r . map (cntJustify ha ' ' c)

-- | A convenience function for rendering a box to stdout.
printBox :: Box String -> IO ()
printBox = putStr . render
