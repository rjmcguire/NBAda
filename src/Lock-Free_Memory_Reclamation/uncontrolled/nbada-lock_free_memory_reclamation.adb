-------------------------------------------------------------------------------
--  Lock-Free Memory Reclamation - An implementation of the lock-free
--  garbage reclamation scheme by A. Gidenstam, M. Papatriantafilou, H. Sundell
--  and P. Tsigas.
--
--  Copyright (C) 2004 - 2008  Anders Gidenstam
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
--  Filename        : lock_free_memory_reclamation.adb
--  Description     : Ada implementation of the lock-free garbage reclamation
--                    Scheme from "Efficient and Reliable Lock-Free Memory
--                    Reclamation Based on Reference Counting",
--                    Anders Gidenstam, Marina Papatriantafilou,
--                    H�kan Sundell and Philippas Tsigas,
--                    Proceedings of the 8th International Symposium on
--                    Parallel Architectures, Algorithms and Networks (I-SPAN),
--                    pages 202 - 207, IEEE Computer Society, 2005.
--  Author          : Anders Gidenstam
--  Created On      : Fri Nov 19 14:07:58 2004
--  $Id: nbada-lock_free_memory_reclamation.adb,v 1.35.2.1 2008/09/17 22:34:25 andersg Exp $
-------------------------------------------------------------------------------
pragma Style_Checks (All_Checks);

pragma License (GPL);

with NBAda.Internals.Hash_Tables;
with NBAda.Internals.Cleanup_Tools;

--  with Ada.Unchecked_Deallocation;
with Ada.Unchecked_Conversion;
with Ada.Exceptions;
with Ada.Tags;

with Ada.Text_IO;

package body NBAda.Lock_Free_Memory_Reclamation is

   ----------------------------------------------------------------------------
   --  Types.
   ----------------------------------------------------------------------------
   subtype Processes  is Process_Ids.Process_ID_Type;
   type    HP_Index   is new Natural range 1 .. Max_Number_Of_Dereferences;
   type    Node_Index is new Natural range 0 .. Max_Delete_List_Size;
   subtype Valid_Node_Index is
     Node_Index range 1 .. Node_Index (Max_Delete_List_Size);

   subtype Atomic_Node_Access is Managed_Node_Access;

   subtype Node_Count  is Natural;
   subtype Claim_Count is Primitives.Unsigned_32;


   procedure Scan           (ID : in Processes);
   procedure Clean_Up_Local (ID : in Processes);
   procedure Clean_Up_All   (ID : in Processes);

   function Hash_Ref (Ref  : in Managed_Node_Access;
                      Size : in Natural) return Natural;

   procedure Fetch_And_Add (Target    : access Primitives.Unsigned_32;
                            Increment : in     Primitives.Unsigned_32)
     renames Primitives.Fetch_And_Add_32;

   package HP_Sets is
      new Internals.Hash_Tables (Managed_Node_Access, "=", Hash_Ref);


   ----------------------------------------------------------------------------
   --  Internal data structures.
   ----------------------------------------------------------------------------

   --  Persistent shared variables.
   type Hazard_Pointer_Array is array (HP_Index) of
     aliased Atomic_Node_Access;
   pragma Volatile (Hazard_Pointer_Array);
   pragma Atomic_Components (Hazard_Pointer_Array);

   type Node_Array is array (Valid_Node_Index) of
     aliased Atomic_Node_Access;
   pragma Volatile (Node_Array);
   pragma Atomic_Components (Node_Array);

   type Claim_Array is array (Valid_Node_Index) of
     aliased Claim_Count;
   pragma Volatile (Claim_Array);
   pragma Atomic_Components (Claim_Array);

   type Done_Array is array (Valid_Node_Index) of aliased Boolean;
   pragma Volatile (Done_Array);
   pragma Atomic_Components (Done_Array);

   type Persistent_Shared is
      record
         Hazard_Pointer : Hazard_Pointer_Array;
         DL_Nodes       : Node_Array;
         DL_Claims      : Claim_Array := (others => 0);
         DL_Done        : Done_Array  := (others => False);
      end record;
   type Persistent_Shared_Access is access Persistent_Shared;

   Persistent_Shared_Variables : constant array (Processes) of
     Persistent_Shared_Access := (others => new Persistent_Shared);
   --  FIXME: Free these during finalization of the package.

   --  Persistent process local variables.
   type DL_Nexts_Array is array (Valid_Node_Index) of Node_Index;
   type Persistent_Local is
     record
        D_List   : Node_Index := 0;
        D_Count  : Node_Count := 0;
        DL_Nexts : DL_Nexts_Array := (others => 0);
     end record;
   type Persistent_Local_Access is access Persistent_Local;

   Persistent_Local_Variables : constant array (Processes) of
     Persistent_Local_Access := (others => new Persistent_Local);
   --  FIXME: Free these during finalization of the package.

   Nodes_Created   : aliased Primitives.Unsigned_32 := 0;
   pragma Atomic (Nodes_Created);
   Nodes_Reclaimed : aliased Primitives.Unsigned_32 := 0;
   pragma Atomic (Nodes_Reclaimed);


   --  The P_Sets are preallocated from the heap as it can easily become
   --  too large to fit on the task stack.
   type HP_Set_Access is access HP_Sets.Hash_Table;
   P_Set : constant array (Processes) of HP_Set_Access :=
     (others => new HP_Sets.Hash_Table
      (Size => 2 * Natural (Process_Ids.Max_Number_Of_Processes *
                            Max_Number_Of_Dereferences) + 1));
   --  FIXME: Free these during finalization of the package.

   ----------------------------------------------------------------------------
   --  Operations.
   ----------------------------------------------------------------------------

   ----------------------------------------------------------------------------
   function Is_Deleted (Node : access Managed_Node_Base)
                       return Boolean is
   begin
      return Node.MM_Del;
   end Is_Deleted;

   ----------------------------------------------------------------------------
   package body Operations is

      ----------------------------------------------------------------------
      function To_Private_Reference is
         new Ada.Unchecked_Conversion (Shared_Reference,
                                       Private_Reference_Impl);
      function To_Private_Reference is
         new Ada.Unchecked_Conversion (Node_Access,
                                       Private_Reference_Impl);

      function To_Node_Access (X : Private_Reference)
                              return Node_Access;
      pragma Inline (To_Node_Access);

      type Shared_Reference_Base_Access is access all Shared_Reference_Base;
      type Shared_Reference_Access is access all Shared_Reference;
      function To_Shared_Reference_Base_Access is
         new Ada.Unchecked_Conversion (Shared_Reference_Access,
                                       Shared_Reference_Base_Access);

      function Compare_And_Swap_Impl is new
        Primitives.Standard_Boolean_Compare_And_Swap (Shared_Reference_Base);

      Mark_Mask  : constant Private_Reference_Impl := 2 ** Mark_Bits - 1;
      Ref_Mask   : constant Private_Reference_Impl := -(2 ** Mark_Bits);

      ----------------------------------------------------------------------
      function Image (R : Private_Reference) return String is
         type Node_Access is access all Managed_Node_Base'Class;
      begin
         if Deref (R) /= null then
            return
              Ada.Tags.External_Tag (Node_Access (Deref (R)).all'Tag) & "@" &
              Private_Reference_Impl'Image (R.Ref);
         else
            return "@" & Private_Reference_Impl'Image (R.Ref);
         end if;
      end Image;

      ----------------------------------------------------------------------
      function  Dereference (Link : access Shared_Reference)
                            return Private_Reference is
         ID       : constant Processes := Process_Ids.Process_ID;
         PS       : Persistent_Shared renames
           Persistent_Shared_Variables (ID).all;
         Index    : HP_Index;
         Found    : Boolean := False;
         Node_Ref : Private_Reference;
      begin
         --  Find a free hazard pointer.
         for I in PS.Hazard_Pointer'Range loop
            if PS.Hazard_Pointer (I) = null then
               Index       := I;
               Node_Ref.HP := Natural (I);
               Found       := True;
               exit;
            end if;
         end loop;
         --  Dereference node iff there is a free hazard pointer.
         if not Found then
            Ada.Exceptions.Raise_Exception
              (Constraint_Error'Identity,
               "lock_free_memory_reclamation.adb: " &
               "Maximum number of local dereferences exceeded!");
         else
            loop
               Node_Ref.Ref := To_Private_Reference (Link.all);
               PS.Hazard_Pointer (Index) :=
                 Atomic_Node_Access (To_Node_Access (Node_Ref));

               Primitives.Membar;
               --  The write to the hazard pointer must be visible
               --  before Link is read again.
               exit when To_Private_Reference (Link.all) = Node_Ref.Ref;
            end loop;
         end if;

         return Node_Ref;
      end Dereference;

      ----------------------------------------------------------------------
      procedure Release (Node : in Private_Reference) is
         ID : constant Processes := Process_Ids.Process_ID;
         PS       : Persistent_Shared renames
           Persistent_Shared_Variables (ID).all;
      begin
         --  Find and clear hazard pointer.
         Primitives.Membar;
         --  Complete all preceding memory operations before releasing
         --  the hazard pointer.
         if (Deref (Node) /= null) then
            --  To Release a Null_Reference is allowed.
            PS.Hazard_Pointer (HP_Index (Node.HP)) := null;
         end if;
      end Release;

      ----------------------------------------------------------------------
      function  "+"     (Node : in Private_Reference)
                        return Node_Access renames To_Node_Access;

      ----------------------------------------------------------------------
      function Deref (Node : in Private_Reference)
                     return Node_Access renames To_Node_Access;

      ----------------------------------------------------------------------
      procedure Delete  (Node : in Private_Reference) is
         use type Node_Count;
         ID    : constant Processes := Process_Ids.Process_ID;
         PS    : Persistent_Shared
           renames Persistent_Shared_Variables (ID).all;
         PL    : Persistent_Local renames Persistent_Local_Variables (ID).all;
         Index : Node_Index;
      begin
         if Deref (Node) = null then
            return;
         end if;

         Release (Node);
         declare
            Node_Base : constant Managed_Node_Access :=
              Managed_Node_Access (To_Node_Access (Node));
            --  Base type view of the node.
         begin
            Node_Base.MM_Del   := True;
            Node_Base.MM_Trace := False;
         end;

         --  Find a free index in DL_Nodes.
         --  This is probably not the best search strategy.
         for I in PS.DL_Nodes'Range loop
            if PS.DL_Nodes (I) = null then
               Index := I;
            end if;
         end loop;

         PS.DL_Done  (Index) := False;
         PS.DL_Nodes (Index) := Atomic_Node_Access (To_Node_Access (Node));
         PL.DL_Nexts (Index) := PL.D_List;
         PL.D_List  := Index;
         PL.D_Count := PL.D_Count + 1;

         loop
            if PL.D_Count >= Natural'Min (Clean_Up_Threshold,
                                          Max_Delete_List_Size) then
               Clean_Up_Local (ID);
            end if;
            if PL.D_Count >= Natural'Min (Scan_Threshold,
                                          Max_Delete_List_Size) then
               Scan (ID);
            end if;
            if PL.D_Count >= Natural'Min (Clean_Up_Threshold,
                                          Max_Delete_List_Size) then
               Clean_Up_All (ID);
            end if;

            exit when PL.D_Count < Max_Delete_List_Size;
         end loop;
      end Delete;

      ----------------------------------------------------------------------
      function  Copy (Node : in Private_Reference)
                     return Private_Reference is
         ID    : constant Processes := Process_Ids.Process_ID;
         PS       : Persistent_Shared
           renames Persistent_Shared_Variables (ID).all;
         Index : HP_Index;
         Found : Boolean := False;
         Copy  : Private_Reference;
      begin
         --  Find a free hazard pointer.
         for I in PS.Hazard_Pointer'Range loop
            if PS.Hazard_Pointer (I) = null then
               Index   := I;
               Copy.HP := Natural (I);
               Found   := True;
               exit;
            end if;
         end loop;
         --  Copy the reference iff there is a free hazard pointer.
         if not Found then
            Ada.Exceptions.Raise_Exception
              (Constraint_Error'Identity,
               "lock_free_memory_reclamation.adb: " &
               "Maximum number of local dereferences exceeded!");
         else
            Copy.Ref := Node.Ref;
            PS.Hazard_Pointer (Index) :=
              Atomic_Node_Access (To_Node_Access (Copy));

            Primitives.Membar;
            --  Make sure the hazard pointer write is committed before
            --  subsequent memory operations.
         end if;

         return Copy;
      end Copy;

      ----------------------------------------------------------------------
      function  Compare_And_Swap (Link      : access Shared_Reference;
                                  Old_Value : in Private_Reference;
                                  New_Value : in Private_Reference)
                                 return Boolean is
         use type Reference_Count;
      begin
         if
           Compare_And_Swap_Impl
           (Target    =>
              To_Shared_Reference_Base_Access (Link.all'Unchecked_Access),
            Old_Value => (Ref => Shared_Reference_Base_Impl (Old_Value.Ref)),
            New_Value => (Ref => Shared_Reference_Base_Impl (New_Value.Ref)))
         then
            if To_Node_Access (New_Value) /= null then
               declare
                  New_Value_Base : constant Managed_Node_Access :=
                    Managed_Node_Access (To_Node_Access (New_Value));
                  --  Base type view of the node.
               begin
                  Fetch_And_Add (New_Value_Base.MM_RC'Access, 1);
                  New_Value_Base.MM_Trace := False;
               end;
            end if;

            if To_Node_Access (Old_Value) /= null then
               declare
                  Old_Value_Base : constant Managed_Node_Access :=
                    Managed_Node_Access (To_Node_Access (Old_Value));
                  --  Base type view of the node.
               begin
                  Fetch_And_Add (Old_Value_Base.MM_RC'Access, -1);
               end;
            end if;

            return True;
         end if;

         return False;
      end Compare_And_Swap;

      ----------------------------------------------------------------------
      procedure Compare_And_Swap (Link      : access Shared_Reference;
                                  Old_Value : in     Private_Reference;
                                  New_Value : in     Private_Reference) is
         use type Reference_Count;
      begin
         if
           Compare_And_Swap (Link,
                             Old_Value,
                             New_Value)
         then
            null;
         end if;
      end Compare_And_Swap;

      ----------------------------------------------------------------------
      procedure Store   (Link : access Shared_Reference;
                         Node : in Private_Reference) is
         use type Reference_Count;

         Old : constant Node_Access :=
           To_Node_Access ((To_Private_Reference (Link.all), 0));
      begin
         To_Shared_Reference_Base_Access (Link.all'Unchecked_Access).all :=
           (Ref => Shared_Reference_Base_Impl (Node.Ref));

         if To_Node_Access (Node) /= null then
            declare
               Node_Base : constant Managed_Node_Access :=
                 Managed_Node_Access (To_Node_Access (Node));
               --  Base type view of the node.
            begin
               Fetch_And_Add (Node_Base.MM_RC'Access, 1);
               Node_Base.MM_Trace := False;
            end;
         end if;

         if Old /= null then
            declare
               Old_Base : constant Managed_Node_Access :=
                 Managed_Node_Access (Old);
               --  Base type view of the node.
            begin
               Fetch_And_Add (Old_Base.MM_RC'Access, -1);
            end;
         end if;
      end Store;

      ----------------------------------------------------------------------
      function Create return Private_Reference is
         ID    : constant Processes        := Process_Ids.Process_ID;
         PS    : Persistent_Shared
           renames Persistent_Shared_Variables (ID).all;
         UNode : constant User_Node_Access := new Managed_Node;
         Node  : constant Node_Access      := UNode.all'Unchecked_Access;
         Index : HP_Index;
         Found : Boolean := False;
      begin
         --  Find a free hazard pointer.
         for I in PS.Hazard_Pointer'Range loop
            if PS.Hazard_Pointer (I) = null then
               Index := I;
               Found := True;
               exit;
            end if;
         end loop;

         if not Found then
            Ada.Exceptions.Raise_Exception
              (Constraint_Error'Identity,
               "lock_free_memory_reclamation.adb: " &
               "Maximum number of local dereferences exceeded!");
         else
            PS.Hazard_Pointer (Index) := Atomic_Node_Access (Node);
         end if;

         if Collect_Statistics then
            Fetch_And_Add (Nodes_Created'Access, 1);
         end if;

         return (To_Private_Reference (Node), Natural (Index));
      end Create;

      ----------------------------------------------------------------------
      procedure Mark      (Node : in out Private_Reference) is
      begin
         Node.Ref := Node.Ref or 1;
      end Mark;

      ----------------------------------------------------------------------
      function  Mark      (Node : in     Private_Reference)
                          return Private_Reference is
      begin
         return (Node.Ref or 1, Node.HP);
      end Mark;

      ----------------------------------------------------------------------
      procedure Unmark    (Node : in out Private_Reference) is
      begin
         Node.Ref := Node.Ref and Ref_Mask;
      end Unmark;

      ----------------------------------------------------------------------
      function  Unmark    (Node : in     Private_Reference)
                          return Private_Reference is
      begin
         return (Node.Ref and Ref_Mask, Node.HP);
      end Unmark;

      ----------------------------------------------------------------------
      function  Is_Marked (Node : in     Private_Reference)
                          return Boolean is
      begin
         return (Node.Ref and Mark_Mask) = 1;
      end Is_Marked;

      ----------------------------------------------------------------------
      function  Is_Marked (Node : in     Shared_Reference)
                          return Boolean is
      begin
         return (To_Private_Reference (Node) and Mark_Mask) = 1;
      end Is_Marked;

      ----------------------------------------------------------------------
      function "=" (Left  : in     Private_Reference;
                    Right : in     Private_Reference) return Boolean is
      begin
         return Left.Ref = Right.Ref;
      end "=";

      ----------------------------------------------------------------------
      function "=" (Link : in     Shared_Reference;
                    Ref  : in     Private_Reference) return Boolean is
      begin
         return To_Private_Reference (Link) = Ref.Ref;
      end "=";

      ----------------------------------------------------------------------
      function "=" (Ref  : in     Private_Reference;
                    Link : in     Shared_Reference) return Boolean is
      begin
         return To_Private_Reference (Link) = Ref.Ref;
      end "=";

      ----------------------------------------------------------------------
      ----------------------------------------------------------------------
      function Unsafe_Read (Link : access Shared_Reference)
                           return Unsafe_Reference_Value is
      begin
         return Unsafe_Reference_Value (To_Private_Reference (Link.all));
      end Unsafe_Read;

      ----------------------------------------------------------------------
      function  Compare_And_Swap (Link      : access Shared_Reference;
                                  Old_Value : in Unsafe_Reference_Value;
                                  New_Value : in Private_Reference)
                                 return Boolean is
      begin
         --  Since we have not dereferenced Old_Value it is not
         --  guaranteed to have a positive reference count.
         --  However, since we just successfully removed a link to that
         --  node it's reference count certainly should not be zero.
         return Compare_And_Swap (Link      => Link,
                                  Old_Value =>
                                    (Ref => Private_Reference_Impl (Old_Value),
                                     HP  => 0),
                                  New_Value => New_Value);
      end Compare_And_Swap;

      ----------------------------------------------------------------------
      procedure Compare_And_Swap (Link      : access Shared_Reference;
                                  Old_Value : in     Unsafe_Reference_Value;
                                  New_Value : in     Private_Reference) is
      begin
         --  Since we have not dereferenced Old_Value it is not
         --  guaranteed to have a positive reference count.
         --  However, since we just successfully removed a link to that
         --  node it's reference count certainly should not be zero.
         if
           Compare_And_Swap (Link      => Link,
                             Old_Value =>
                               (Ref => Private_Reference_Impl (Old_Value),
                                HP  => 0),
                             New_Value => New_Value)
         then
            null;
         end if;
      end Compare_And_Swap;

      ----------------------------------------------------------------------
      function  Compare_And_Swap (Link      : access Shared_Reference;
                                  Old_Value : in Unsafe_Reference_Value;
                                  New_Value : in Unsafe_Reference_Value)
                                 return Boolean is
      begin
         --  Since we have not dereferenced Old_Value it is not
         --  guaranteed to have a positive reference count.
         --  However, since we just successfully removed a link to that
         --  node it's reference count certainly should not be zero.
         --  NOTE: The New_Value could easily be dangerous.
         return Compare_And_Swap (Link      => Link,
                                  Old_Value =>
                                    (Ref => Private_Reference_Impl (Old_Value),
                                     HP  => 0),
                                  New_Value =>
                                    (Ref => Private_Reference_Impl (New_Value),
                                     HP  => 0));
      end Compare_And_Swap;

      ----------------------------------------------------------------------
      procedure Compare_And_Swap (Link      : access Shared_Reference;
                                  Old_Value : in     Unsafe_Reference_Value;
                                  New_Value : in     Unsafe_Reference_Value) is
      begin
         --  Since we have not dereferenced Old_Value it is not
         --  guaranteed to have a positive reference count.
         --  However, since we just successfully removed a link to that
         --  node it's reference count certainly should not be zero.
         if
           Compare_And_Swap (Link      => Link,
                             Old_Value =>
                               (Ref => Private_Reference_Impl (Old_Value),
                                HP  => 0),
                             New_Value =>
                               (Ref => Private_Reference_Impl (New_Value),
                                HP  => 0))
         then
            null;
         end if;
      end Compare_And_Swap;

      ----------------------------------------------------------------------
      function  Is_Marked (Node : in     Unsafe_Reference_Value)
                          return Boolean is
      begin
         return (Private_Reference_Impl (Node) and Mark_Mask) =
           Private_Reference_Impl'(1);
      end Is_Marked;

      ----------------------------------------------------------------------
      function  Mark      (Node : in     Unsafe_Reference_Value)
                          return Unsafe_Reference_Value is
      begin
         return Node or 1;
      end Mark;

      ----------------------------------------------------------------------
      function "=" (Val : in     Unsafe_Reference_Value;
                    Ref : in     Private_Reference) return Boolean is
      begin
         return Ref.Ref = Private_Reference_Impl (Val);
      end "=";


      ----------------------------------------------------------------------
      function "=" (Ref : in     Private_Reference;
                    Val : in     Unsafe_Reference_Value) return Boolean is
      begin
         return Ref.Ref = Private_Reference_Impl (Val);
      end "=";

      ----------------------------------------------------------------------
      function "=" (Link : in     Shared_Reference;
                    Ref  : in     Unsafe_Reference_Value) return Boolean is
      begin
         return To_Private_Reference (Link) = Private_Reference_Impl (Ref);
      end "=";

      ----------------------------------------------------------------------
      function "=" (Ref  : in     Unsafe_Reference_Value;
                    Link : in     Shared_Reference) return Boolean is
      begin
         return To_Private_Reference (Link) = Private_Reference_Impl (Ref);
      end "=";

      ----------------------------------------------------------------------
      ----------------------------------------------------------------------
      function To_Node_Access (X : Private_Reference)
                              return Node_Access is

         function To_Node_Access is
            new Ada.Unchecked_Conversion (Private_Reference_Impl,
                                          Node_Access);

      begin
         return To_Node_Access (X.Ref and Ref_Mask);
      end To_Node_Access;

      ----------------------------------------------------------------------
   end Operations;

   ----------------------------------------------------------------------------
   procedure Print_Statistics is
      use type Primitives.Unsigned_32;

      function Count_Unreclaimed return Primitives.Unsigned_32;
      function Count_HPs_Set return Natural;

      -----------------------------------------------------------------
      function Count_Unreclaimed return Primitives.Unsigned_32 is
         Count : Primitives.Unsigned_32 := 0;
      begin
         --  Note: This is not thread safe.
         for P in Persistent_Local_Variables'Range loop
            Count := Count +
              Primitives.Unsigned_32 (Persistent_Local_Variables (P).D_Count);
         end loop;
         return Count;
      end Count_Unreclaimed;

      -----------------------------------------------------------------
      function Count_HPs_Set return Natural is
         Count : Natural := 0;
      begin
         --  Note: This is not thread safe.
         for P in Persistent_Shared_Variables'Range loop
            for I in Persistent_Shared_Variables (P).Hazard_Pointer'Range loop
               if
                 Persistent_Shared_Variables (P).Hazard_Pointer (I) /= null
               then
                  Count := Count + 1;
               end if;
            end loop;
         end loop;
         return Count;
      end Count_HPs_Set;

      -----------------------------------------------------------------
   begin
      Ada.Text_IO.Put_Line ("Lock_Free_Memory_Reclamation.Print_Statistics:");
      Ada.Text_IO.Put_Line ("  #Created = " &
                            Primitives.Unsigned_32'Image (Nodes_Created));
      Ada.Text_IO.Put_Line ("  #Reclaimed = " &
                            Primitives.Unsigned_32'Image (Nodes_Reclaimed));

      Ada.Text_IO.Put_Line ("  #Awaiting reclamation = " &
                            Primitives.Unsigned_32'Image
                            (Count_Unreclaimed));
      Ada.Text_IO.Put_Line
        ("  #Not accounted for = " &
         Primitives.Unsigned_32'Image
         (Nodes_Created - Nodes_Reclaimed - Count_Unreclaimed));
      Ada.Text_IO.Put_Line ("  #Hazard pointers set = " &
                            Integer'Image (Count_HPs_Set));
   end Print_Statistics;

   ----------------------------------------------------------------------------
   --  Internal operations.
   ----------------------------------------------------------------------------

   ----------------------------------------------------------------------------
   procedure Scan (ID : in Processes) is
      use type Reference_Count;
      use HP_Sets;

      PS          : Persistent_Shared
        renames Persistent_Shared_Variables (ID).all;
      PL          : Persistent_Local
        renames Persistent_Local_Variables (ID).all;
      Index       : Node_Index;
      Node        : Atomic_Node_Access;
      New_D_List  : Node_Index := 0;
      New_D_Count : Node_Count := 0;
   begin
      --  Set the trace bit on each deleted node with MM_RC = 0.
      Index := PL.D_List;
      while Index /= 0 loop
         Node := PS.DL_Nodes (Index);
         if Node.MM_RC = 0 then
            Primitives.Membar;
            --  The read of MM_RC must precede the write of MM_trace.
            Node.MM_Trace := True;
            Primitives.Membar;
            --  The write of MM_Trace must precede the reread of MM_RC.
            if Node.MM_RC /= 0 then
               Node.MM_Trace := False;
            end if;
         end if;
         Index := PL.DL_Nexts (Index);
      end loop;
      Primitives.Membar;
      --  Make sure the memory operations of the algorithm's phases are
      --  separated.

      Clear (P_Set (ID).all);

      --  Read all hazard pointers.
      for P in Processes loop
         for I in HP_Index loop
            Node := Persistent_Shared_Variables (P).Hazard_Pointer (I);
            if Node /= null then
               declare
                  N : constant Managed_Node_Access :=
                    Managed_Node_Access (Node);
               begin
                  Insert (N, P_Set (ID).all);
               end;
            end if;
         end loop;
      end loop;
      Primitives.Membar;
      --  Make sure the memory operations of the algorithm's phases are
      --  separated.

      --  Attempt to reclaim nodes.
      while PL.D_List /= 0 loop
         Index       := PL.D_List;
         Node        := PS.DL_Nodes (Index);
         PL.D_List   := PL.DL_Nexts (Index);

         if Node.MM_RC = 0 and Node.MM_Trace and
           not Member (Managed_Node_Access (Node), P_Set (ID).all)
         then
            PS.DL_Nodes (Index) := null;
            Primitives.Membar;
            --  The write to DL_Nodes (ID, Index) must precede the
            --  read of DL_Claims (ID, Index).
            if PS.DL_Claims (Index) = 0 then
               Dispose (Managed_Node_Access (Node),
                        Concurrent => False);
               Free (Managed_Node_Access (Node));

               if Collect_Statistics then
                  Fetch_And_Add (Nodes_Reclaimed'Access, 1);
               end if;
            else
               Dispose (Managed_Node_Access (Node),
                        Concurrent => True);
               PS.DL_Done  (Index) := True;
               PS.DL_Nodes (Index) := Node;

               --  Keep Node in D_List.
               PL.DL_Nexts (Index) := New_D_List;
               New_D_List   := Index;
               New_D_Count  := New_D_Count + 1;
            end if;
         else
            --  Keep Node in D_List.
            PL.DL_Nexts (Index) := New_D_List;
            New_D_List   := Index;
            New_D_Count  := New_D_Count + 1;
         end if;
      end loop;

      PL.D_List  := New_D_List;
      PL.D_Count := New_D_Count;

--        Free (P_Set);
   end Scan;

   ----------------------------------------------------------------------------
   procedure Clean_Up_Local (ID : in Processes) is
      PS    : Persistent_Shared renames Persistent_Shared_Variables (ID).all;
      PL    : Persistent_Local renames Persistent_Local_Variables (ID).all;
      Index : Node_Index := PL.D_List;
      Node  : Atomic_Node_Access;
   begin
      while Index /= 0 loop
         Node  := PS.DL_Nodes (Index);
         Clean_Up (Managed_Node_Access (Node));
         Index := PL.DL_Nexts (Index);
      end loop;
   end Clean_Up_Local;

   ----------------------------------------------------------------------------
   procedure Clean_Up_All (ID : in Processes) is
      use type Primitives.Unsigned_32;
      use type Processes;
      Node  : Atomic_Node_Access;
   begin
      for P in Processes loop
         if P /= ID then
            for Index in Valid_Node_Index loop
               Node := Persistent_Shared_Variables (P).DL_Nodes (Index);
               if
                 Node /= null and then
                 not Persistent_Shared_Variables (P).DL_Done (Index)
               then
                  Fetch_And_Add
                    (Target    => Persistent_Shared_Variables (P).
                                    DL_Claims (Index)'Access,
                     Increment => 1);
                  if
                    Node = Persistent_Shared_Variables (P).DL_Nodes (Index)
                  then
                     Clean_Up (Managed_Node_Access (Node));
                  end if;
                  Fetch_And_Add
                    (Target    => Persistent_Shared_Variables (P).
                                    DL_Claims (Index)'Access,
                     Increment => -1);
               end if;
            end loop;
         end if;
      end loop;
   end Clean_Up_All;

   ----------------------------------------------------------------------------
   function Hash_Ref (Ref  : in Managed_Node_Access;
                      Size : in Natural) return Natural is
      use type Primitives.Standard_Unsigned;
      function To_Unsigned is
         new Ada.Unchecked_Conversion (Managed_Node_Access,
                                       Primitives.Standard_Unsigned);
   begin
      return Natural
        ((To_Unsigned (Ref) / 4) mod Primitives.Standard_Unsigned (Size));
   end Hash_Ref;

   ----------------------------------------------------------------------------
   procedure Finalize;

   procedure Finalize is
   begin
      if Collect_Statistics then
         Print_Statistics;
      end if;
   end Finalize;

   type Local_Action is access procedure;
   function Lope_Hole is new Ada.Unchecked_Conversion
     (Local_Action,
      NBAda.Internals.Cleanup_Tools.Action);

   Finally :
     NBAda.Internals.Cleanup_Tools.On_Exit (Lope_Hole (Finalize'Access));
--  NOTE: This is a really really dangerous idea!
--        Finally might be destroyed AFTER the node storage pool is destroyed!

end NBAda.Lock_Free_Memory_Reclamation;
