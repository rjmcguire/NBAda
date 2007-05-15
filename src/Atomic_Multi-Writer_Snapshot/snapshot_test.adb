-------------------------------------------------------------------------------
--  Atomic M-component N-process snapshot implementation based on P. Jayanti,
--  "An Optimal Multi-Writer Snapshot Algorithm", Proceedings of STOC'05,
--  ACM, 2005.
--
--  Copyright (C) 2007  Anders Gidenstam
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
--                              -*- Mode: Ada -*-
--  Filename        : snapshot_test.adb
--  Description     : Test benchamrk for M-component N-process snapshot
--                    implementation based on P. Jayanti,
--                    "An Optimal Multi-Writer Snapshot Algorithm",
--                    Proceedings of STOC'05, ACM, 2005.
--  Author          : Anders Gidenstam
--  Created On      : Tue May 15 13:19:07 2007
-- $Id: snapshot_test.adb,v 1.1 2007/05/15 14:02:15 andersg Exp $
-------------------------------------------------------------------------------

pragma License (GPL);

with Ada.Text_IO;
with Ada.Exceptions;

with Ada.Real_Time;

with System.Task_Info;

with Process_Identification;
with Primitives;
with Atomic_Multiwriter_Snapshots;

procedure Snapshot_Test is

   package PID is
      new Process_Identification (Max_Number_Of_Processes => 32);

   package My_Snapshot is
      new Atomic_Multiwriter_Snapshots (Process_Ids              => PID,
                                        Max_Number_Of_Components => 32);

   package Integer_Components is
      new My_Snapshot.Element_Components (Element => Integer);
   subtype Integer_Component is Integer_Components.Element_Component;

   ----------------------------------------------------------------------------
   --  Test application.
   ----------------------------------------------------------------------------

   ----------------------------------------------------------------------
   Output_File : Ada.Text_IO.File_Type renames
     Ada.Text_IO.Standard_Output;
--     Ada.Text_IO.Standard_Error;

   No_Of_Writes : constant := 100_000;

   ----------------------------------------------------------------------
   function Pinned_Task return System.Task_Info.Task_Info_Type;

   task type Writer is
      pragma Task_Info (Pinned_Task);
      pragma Storage_Size (1 * 1024 * 1024);
   end Writer;

   task type Reader is
      pragma Task_Info (Pinned_Task);
      pragma Storage_Size (1 * 1024 * 1024);
   end Reader;

   ----------------------------------------------------------------------
   My_Components : constant array (1 .. 10) of Integer_Component :=
     (others => Integer_Components.Create (Default_Value => 42));

   Start              : aliased Primitives.Unsigned_32 := 0;
   Write_Count        : aliased Primitives.Unsigned_32 := 0;
   Scan_Count         : aliased Primitives.Unsigned_32 := 0;
   No_Writers_Running : aliased Primitives.Unsigned_32 := 0;
   No_Readers_Running : aliased Primitives.Unsigned_32 := 0;

   ----------------------------------------------------------------------
   --   Task_Count : aliased Primitives.Unsigned_32 := 0;
   function Pinned_Task return System.Task_Info.Task_Info_Type is
   begin
      --  GNAT/IRIX
--        return new System.Task_Info.Thread_Attributes'
--          (Scope       => System.Task_Info.PTHREAD_SCOPE_SYSTEM,
--           Inheritance => System.Task_Info.PTHREAD_EXPLICIT_SCHED,
--           Policy      => System.Task_Info.SCHED_RR,
--           Priority    => System.Task_Info.No_Specified_Priority,
--           Runon_CPU   =>
--             --System.Task_Info.ANY_CPU
--             Integer (Primitives.Fetch_And_Add_32 (Task_Count'Access, 1))
--           );
      --  GNAT/Linux
      return System.Task_Info.System_Scope;
      --  GNAT/Solaris
--      return System.Task_Info.New_Bound_Thread_Attributes;
   end Pinned_Task;

   ----------------------------------------------------------------------
   task body Writer is
      No_Writes : Primitives.Unsigned_32 := 0;
      Component : Natural;
   begin
      PID.Register;
      Component :=
        (Natural (Primitives.Fetch_And_Add_32 (No_Writers_Running'Access, 1))
         mod 10) + 1;

      declare
         use type Primitives.Unsigned_32;
      begin
         while Start = 0 loop
            null;
         end loop;
      end;

      declare
         use Integer_Components;
         ID          : constant PID.Process_ID_Type := PID.Process_ID;
      begin
         for I in 1 .. No_Of_Writes loop
            Write (My_Components (Component), I);
            No_Writes := Primitives.Unsigned_32'Succ (No_Writes);
         end loop;

      exception
         when E : others =>
            Ada.Text_IO.New_Line (Output_File);
            Ada.Text_IO.Put_Line (Output_File,
                                  "Writer (" &
                                  PID.Process_ID_Type'Image (ID) &
                                  "): raised " &
                                  Ada.Exceptions.Exception_Name (E) &
                                  " : " &
                                  Ada.Exceptions.Exception_Message (E));
            Ada.Text_IO.New_Line (Output_File);
      end;
      declare
         use type Primitives.Unsigned_32;
      begin
         Primitives.Fetch_And_Add_32 (Write_Count'Access, No_Writes);
         Primitives.Fetch_And_Add_32 (No_Writers_Running'Access, -1);
      end;
      Ada.Text_IO.Put_Line (Output_File,
                            "Writer (?): exited.");

   exception
      when E : others =>
         Ada.Text_IO.New_Line (Output_File);
         Ada.Text_IO.Put_Line (Output_File,
                               "Writer (?): raised " &
                               Ada.Exceptions.Exception_Name (E) &
                               " : " &
                               Ada.Exceptions.Exception_Message (E));
         Ada.Text_IO.New_Line (Output_File);
   end Writer;

   ----------------------------------------------------------------------
   task body Reader is
      No_Scans : Primitives.Unsigned_32 := 0;
   begin
      PID.Register;
      Primitives.Fetch_And_Add_32 (No_Readers_Running'Access, 1);

      declare
         use type Primitives.Unsigned_32;
      begin
         while Start = 0 loop
            null;
         end loop;
      end;

      declare
         use Integer_Components;
         use type Primitives.Unsigned_32;
         ID          : constant PID.Process_ID_Type := PID.Process_ID;
      begin
         loop
            declare
               S : constant My_Snapshot.Snapshot := My_Snapshot.Scan;
            begin
               No_Scans := Primitives.Unsigned_32'Succ (No_Scans);
            end;

            exit when No_Writers_Running = 0;
         end loop;

      exception
         when E : others =>
            Ada.Text_IO.New_Line (Output_File);
            Ada.Text_IO.Put_Line (Output_File,
                                  "Reader (" &
                                  PID.Process_ID_Type'Image (ID) &
                                  "): raised " &
                                  Ada.Exceptions.Exception_Name (E) &
                                  " : " &
                                  Ada.Exceptions.Exception_Message (E));
            Ada.Text_IO.New_Line (Output_File);
      end;
      declare
         use type Primitives.Unsigned_32;
      begin
         Primitives.Fetch_And_Add_32 (Scan_Count'Access, No_Scans);
         Primitives.Fetch_And_Add_32 (No_Readers_Running'Access, -1);
      end;
      Ada.Text_IO.Put_Line (Output_File,
                            "Reader (?): exited.");

   exception
      when E : others =>
         Ada.Text_IO.New_Line (Output_File);
         Ada.Text_IO.Put_Line (Output_File,
                               "Reader (?): raised " &
                               Ada.Exceptions.Exception_Name (E) &
                               " : " &
                               Ada.Exceptions.Exception_Message (E));
         Ada.Text_IO.New_Line (Output_File);
   end Reader;

   ----------------------------------------------------------------------
   use type Ada.Real_Time.Time;
   T1, T2 : Ada.Real_Time.Time;
begin
   PID.Register;

   Ada.Text_IO.Put ("Initializing: ");
   Ada.Text_IO.Put_Line (" Done. ");

   Ada.Text_IO.Put_Line ("Testing with writer/scanner tasks.");
   declare
      use type Primitives.Unsigned_32;
      W0, W1, W2, W3, W4, W5, W6, W7
        : Writer;
      R0, R1, R2, R3
        : Reader;
   begin
      delay 5.0;
      T1 := Ada.Real_Time.Clock;
      Primitives.Fetch_And_Add_32 (Start'Access, 1);
   end;
   T2 := Ada.Real_Time.Clock;

   delay 1.0;
   Ada.Text_IO.Put_Line ("Write count: " &
                         Primitives.Unsigned_32'Image (Write_Count));
   Ada.Text_IO.Put_Line ("Scan count: " &
                         Primitives.Unsigned_32'Image (Scan_Count));
   Ada.Text_IO.Put_Line ("Elapsed time:" &
                         Duration'Image (Ada.Real_Time.To_Duration (T2 - T1)) &
                         " seconds.");
end Snapshot_Test;
