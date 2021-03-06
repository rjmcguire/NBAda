-------------------------------------------------------------------------------
--  NBAda - A library of non-blocking algorithms and data structures.
--
--  Copyright (C) 2004 - 2007  Anders Gidenstam
--
--  This program is free software; you can redistribute it and/or modify
--  it under the terms of the GNU General Public License as published by
--  the Free Software Foundation; either version 2 of the License, or
--  (at your option) any later version.
--
--  This program is distributed in the hope that it will be useful,
--  but WITHOUT ANY WARRANTY; without even the implied warranty of
--  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
--  GNU General Public License for more details.
--
--  You should have received a copy of the GNU General Public License
--  along with this program; if not, write to the Free Software
--  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
--
-------------------------------------------------------------------------------
pragma Style_Checks (Off);
-------------------------------------------------------------------------------
--                              -*- Mode: Ada -*-
--  Filename        : hash_tables.ads
--  Description     : A simple closed hash table.
--  Author          : Anders Gidenstam
--  Created On      : Thu Nov 25 21:51:42 2004
--  $Id: nbada-internals-hash_tables.ads,v 1.8 2007/08/30 16:15:38 andersg Exp $
-------------------------------------------------------------------------------
pragma Style_Checks (All_Checks);

pragma License (GPL);

generic
   type Element_Type is private;
   with function "=" (Left, Right : Element_Type) return Boolean is <>;
   with function Hash (Key        : Element_Type;
                       Table_Size : Positive) return Natural;

package NBAda.Internals.Hash_Tables is

   pragma Elaborate_Body;

   type Hash_Table (Size : Positive) is private;

   procedure Clear (Table :    out Hash_Table);
   --  Clear a hash table.

   procedure Insert (Key   : in     Element_Type;
                     Table : in out Hash_Table);
   --  Insert an element.

   procedure Delete (Key   : in     Element_Type;
                     Table : in out Hash_Table);
   --  Delete an element.

   function Member (Key   : in Element_Type;
                    Table : in Hash_Table) return Boolean;
   --  Find an element.

   procedure Find (Key   : in out Element_Type;
                   Table : in     Hash_Table);
   --  Find an element.

   function Find (Key   : in Element_Type;
                  Table : in Hash_Table) return Element_Type;
   --  Find an element.

   Item_Not_Found : exception;

   type Element_Array is array (Natural range <>) of Element_Type;
   function To_Array (Table : in Hash_Table) return Element_Array;

private

   type Entry_Status is (Valid, Empty, Deleted);

   type Hash_Entry is
      record
         Element : Element_Type;
         Status  : Entry_Status := Empty;
      end record;

   subtype Hash_Index is Natural;
   type Hash_Array is array (Hash_Index range <>) of Hash_Entry;

   type Hash_Table (Size : Positive) is
      record
         Table : Hash_Array (0 .. Size);
      end record;

end NBAda.Internals.Hash_Tables;
